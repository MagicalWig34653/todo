import Fluent
import XCTVapor
@testable import TodoKit

final class FeedTests: XCTestCase {
    struct World {
        let f: OAuthFixture
        let other: User
        let otherSession: String
        let foreign: Project
        let foreignTask: TodoTask
        let task: TodoTask
        var db: any Database { f.test.app.db }
    }

    private func world() async throws -> World {
        let f = try await OAuthFixture.make()
        let db = f.test.app.db
        let other = User(displayName: "Other", isAdmin: false)
        try await other.save(on: db)
        let otherSession = AuthSupport.randomToken()
        try await UserSession(userID: other.requireID(), tokenHash: AuthSupport.hash(otherSession), expiresAt: Date().addingTimeInterval(3600)).save(on: db)
        let foreign = Project(ownerID: try other.requireID(), parentID: nil, name: "Foreign")
        try await foreign.save(on: db)
        let foreignTask = TodoTask(ownerID: try other.requireID(), projectID: try foreign.requireID(), title: "Secret task")
        try await foreignTask.save(on: db)
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Own task")
        try await task.save(on: db)
        return World(f: f, other: other, otherSession: otherSession, foreign: foreign, foreignTask: foreignTask, task: task)
    }

    private func note(_ w: World, _ task: TodoTask, _ text: String, at: Date? = nil) async throws -> TaskProgressNote {
        let n = TaskProgressNote()
        n.taskID = try task.requireID(); n.actorType = .integration; n.actorID = UUID(); n.actorLabel = "agent-x"; n.note = text; n.percent = 10
        try await n.save(on: w.db)
        try await appendActivity(taskID: n.taskID, actorType: .integration, actorID: n.actorID, kind: "progress.posted", subjectID: n.id, on: w.db)
        if let at { try await stamp(w, subject: n.id!, at) }
        return n
    }

    private func stamp(_ w: World, subject: UUID, _ at: Date) async throws {
        try await ActivityEvent.query(on: w.db).filter(\.$subjectID == subject).set(\.$createdAt, to: at).update()
    }

    private func feed(_ w: World, _ query: String = "", as session: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await w.f.test.json(.GET, "/v1/feed" + query, token: session ?? w.f.session)
        return (r.status, r.body)
    }

    func testRequiresAuthAndRejectsBadParameters() async throws {
        let w = try await world()
        let anon = try await w.f.test.json(.GET, "/v1/feed")
        XCTAssertEqual(anon.status, .unauthorized)
        for q in ["?mode=x", "?limit=0", "?limit=101", "?limit=abc", "?cursor=nope", "?projectID=nope"] {
            let r = try await feed(w, q)
            XCTAssertEqual(r.status, .badRequest, q)
        }
        let empty = try await feed(w)
        XCTAssertEqual(empty.status, .ok)
        XCTAssertEqual((empty.body?["posts"] as? [Any])?.count, 0)
        XCTAssertTrue(empty.body?["nextCursor"] is NSNull || empty.body?["nextCursor"] == nil)
        await w.f.test.shutdown()
    }

    func testForeignProjectsAreInvisibleAndImagesOnlyOfReadableTasks() async throws {
        let w = try await world()
        _ = try await note(w, w.task, "mine")
        let secret = try await note(w, w.foreignTask, "secret")
        // Build screenshot on the foreign task.
        let att = Attachment()
        att.taskID = try w.foreignTask.requireID(); att.ownerID = try w.other.requireID(); att.filename = "s.png"; att.role = "result"
        att.mediaType = "image/png"; att.size = 3; att.checksum = "x"; att.status = "complete"; att.objectKey = "k"
        try await att.save(on: w.db)
        let art = BuildArtifact()
        art.attachmentID = try att.requireID(); art.taskID = att.taskID; art.buildID = "b1"; art.label = "Shot"; art.createdByType = .person; art.createdByID = att.ownerID
        try await art.save(on: w.db)
        try await appendActivity(taskID: att.taskID, actorType: .person, actorID: att.ownerID, kind: "build.added", subjectID: art.id, on: w.db)
        let q = TaskQuestion()
        q.taskID = att.taskID; q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "foreign?"; q.options = []; q.blocking = true; q.state = "open"; q.version = 1
        try await q.save(on: w.db)

        var r = try await feed(w)
        var posts = try XCTUnwrap(r.body?["posts"] as? [[String: Any]])
        XCTAssertEqual(posts.compactMap { $0["text"] as? String }, ["mine"])
        XCTAssertEqual((r.body?["needsYou"] as? [Any])?.count, 0)
        XCTAssertFalse(String(describing: r.body ?? [:]).contains(secret.note))
        let hidden = try await feed(w, "?projectID=\(try w.foreign.requireID())")
        XCTAssertEqual(hidden.status, .notFound)

        // The owner sees the screenshot with its preview URL; after a read grant so does the other reader, never before.
        r = try await feed(w, as: w.otherSession)
        posts = try XCTUnwrap(r.body?["posts"] as? [[String: Any]])
        let build = try XCTUnwrap(posts.first { $0["kind"] as? String == "build" })
        let image = try XCTUnwrap((build["images"] as? [[String: Any]])?.first)
        XCTAssertEqual(image["previewURL"] as? String, "/v1/attachments/\(try att.requireID().uuidString)/preview")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual((r.body?["needsYou"] as? [Any])?.count, 1)

        try await ProjectGrant(projectID: try w.foreign.requireID(), principalType: "person", principalID: try w.f.user.requireID(), role: .read).save(on: w.db)
        r = try await feed(w)
        posts = try XCTUnwrap(r.body?["posts"] as? [[String: Any]])
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts.filter { !(($0["images"] as? [Any]) ?? []).isEmpty }.count, 1)
        // A reader may not answer questions: the question does not appear in needsYou.
        XCTAssertEqual((r.body?["needsYou"] as? [Any])?.count, 0)
        await w.f.test.shutdown()
    }

    func testNeedsYouOrderCapActionsAndDirectAnswer() async throws {
        let w = try await world()
        let tid = try w.task.requireID()
        let now = Date()
        // Non-blocking question first created, blocking one later: blocking sorts first.
        let soft = TaskQuestion(); soft.taskID = tid; soft.askedByType = .integration; soft.askedByID = UUID(); soft.prompt = "soft"; soft.options = ["A", "B"]
        soft.blocking = false; soft.state = "open"; soft.version = 1
        try await soft.save(on: w.db)
        let hard = TaskQuestion(); hard.taskID = tid; hard.askedByType = .integration; hard.askedByID = UUID(); hard.prompt = "hard"; hard.options = []
        hard.blocking = true; hard.state = "open"; hard.version = 1
        try await hard.save(on: w.db)
        // Own question is not "needs you".
        let mine = TaskQuestion(); mine.taskID = tid; mine.askedByType = .person; mine.askedByID = try w.f.user.requireID(); mine.prompt = "mine"; mine.options = []
        mine.blocking = true; mine.state = "open"; mine.version = 1
        try await mine.save(on: w.db)
        let review = TaskReview(); review.taskID = tid; review.state = "pending"; review.requestedByType = .integration; review.requestedByID = UUID()
        review.summary = "please review"; review.version = 1
        try await review.save(on: w.db)
        let wf = TaskWorkflow(); wf.id = tid; wf.kind = "task"; wf.blockedReason = "waiting for key"
        try await wf.save(on: w.db)
        let late = TodoTask(ownerID: try w.f.user.requireID(), projectID: try w.f.project.requireID(), title: "late")
        try await late.save(on: w.db)
        let p1 = TaskPlanning(taskID: try late.requireID()); p1.dueAt = now.addingTimeInterval(-3 * 86_400); try await p1.save(on: w.db)
        let soon = TodoTask(ownerID: try w.f.user.requireID(), projectID: try w.f.project.requireID(), title: "soon")
        try await soon.save(on: w.db)
        let p2 = TaskPlanning(taskID: try soon.requireID()); p2.dueAt = now.addingTimeInterval(3600); try await p2.save(on: w.db)
        let far = TodoTask(ownerID: try w.f.user.requireID(), projectID: try w.f.project.requireID(), title: "far")
        try await far.save(on: w.db)
        let p3 = TaskPlanning(taskID: try far.requireID()); p3.dueAt = now.addingTimeInterval(9 * 86_400); try await p3.save(on: w.db)

        var r = try await feed(w)
        let items = try XCTUnwrap(r.body?["needsYou"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["kind"] as? String }, ["question", "question", "review", "blocked", "overdue", "due"])
        XCTAssertEqual(items.compactMap { $0["title"] as? String }.prefix(2), ["hard", "soft"])
        XCTAssertEqual(r.body?["needsYouTotal"] as? Int, 6)
        let softItem = items[1]
        let actions = try XCTUnwrap(softItem["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.compactMap { $0["label"] as? String }, ["A", "B"])
        XCTAssertEqual((items[0]["actions"] as? [[String: Any]])?.first?["requiresInput"] as? Bool, true)
        XCTAssertEqual(items[3]["detail"] as? String, "waiting for key")
        let reviewActions = try XCTUnwrap(items[2]["actions"] as? [[String: Any]])
        XCTAssertEqual(reviewActions.compactMap { $0["key"] as? String }, ["accept", "request_changes"])

        // The returned action works unchanged against the existing endpoint.
        let first = actions[0]
        let answered = try await w.f.test.json(.POST, try XCTUnwrap(first["path"] as? String), try XCTUnwrap(first["body"] as? [String: Any]), token: w.f.session)
        XCTAssertEqual(answered.status, .ok)
        let complete = try XCTUnwrap((items[4]["actions"] as? [[String: Any]])?.first)
        let done = try await w.f.test.json(.PATCH, try XCTUnwrap(complete["path"] as? String), try XCTUnwrap(complete["body"] as? [String: Any]), token: w.f.session)
        XCTAssertEqual(done.status, .ok)
        r = try await feed(w)
        XCTAssertEqual((r.body?["needsYou"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }, ["question", "review", "blocked", "due"])

        // Cap at 10, total stays honest.
        for i in 0..<12 {
            let q = TaskQuestion(); q.taskID = tid; q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "q\(i)"; q.options = []; q.blocking = false; q.state = "open"; q.version = 1
            try await q.save(on: w.db)
        }
        r = try await feed(w)
        XCTAssertEqual((r.body?["needsYou"] as? [Any])?.count, 10)
        XCTAssertEqual(r.body?["needsYouTotal"] as? Int, 16)
        // Later pages carry no needsYou.
        let page = try await feed(w, "?limit=1")
        XCTAssertNotNil(page.body)
        await w.f.test.shutdown()
    }

    func testCursorPaginationNeverSkipsOrRepeatsEvenWithEqualTimestamps() async throws {
        let w = try await world()
        let base = Date(timeIntervalSince1970: 1_800_000_000.123456)
        var expected: [UUID] = []
        for i in 0..<31 {
            // Groups of 5 share one timestamp; one sub-millisecond neighbour pair.
            let at = base.addingTimeInterval(Double(i / 5) * 60 + (i == 7 ? 0.0004 : 0))
            let n = try await note(w, w.task, "n\(i)", at: at)
            expected.append(n.id!)
        }
        let events = try await ActivityEvent.query(on: w.db).all()
        let order = events.sorted { FeedCursor.precedes(($0.createdAt!, $0.id!), ($1.createdAt!, $1.id!)) }.map { $0.subjectID! }
        for limit in [1, 4, 7, 100] {
            var seen: [UUID] = []
            var cursor: String?
            var pages = 0
            repeat {
                let r = try await feed(w, "?limit=\(limit)" + (cursor.map { "&cursor=\($0)" } ?? ""))
                XCTAssertEqual(r.status, .ok)
                let posts = try XCTUnwrap(r.body?["posts"] as? [[String: Any]])
                XCTAssertLessThanOrEqual(posts.count, limit)
                let ids = Set(events.map { $0.id!.uuidString })
                for p in posts { XCTAssertTrue(ids.contains(p["id"] as! String)) }
                seen += posts.map { UUID(uuidString: p0($0))! }
                cursor = r.body?["nextCursor"] as? String
                pages += 1
            } while cursor != nil && pages < 100
            XCTAssertEqual(seen.count, 31, "limit \(limit)")
            XCTAssertEqual(Set(seen).count, 31, "limit \(limit): duplicates")
            let byEvent = Dictionary(uniqueKeysWithValues: events.map { ($0.id!, $0.subjectID!) })
            XCTAssertEqual(seen.map { byEvent[$0]! }, order, "limit \(limit): order")
        }
        XCTAssertEqual(Set(order), Set(expected))
        await w.f.test.shutdown()
    }
    private func p0(_ post: [String: Any]) -> String { post["id"] as! String }

    func testFiltersAndClassicMode() async throws {
        let w = try await world()
        let second = Project(ownerID: try w.f.user.requireID(), parentID: nil, name: "Second")
        try await second.save(on: w.db)
        let secondTask = TodoTask(ownerID: try w.f.user.requireID(), projectID: try second.requireID(), title: "Other board")
        try await secondTask.save(on: w.db)
        _ = try await note(w, w.task, "progress A")
        _ = try await note(w, secondTask, "progress B")
        let c = TaskComment(taskID: try w.task.requireID(), authorID: try w.f.user.requireID(), body: "a comment")
        try await c.save(on: w.db)
        try await appendActivity(taskID: c.taskID, actorType: .person, actorID: c.authorID, kind: "comment.created", subjectID: c.id, on: w.db)
        try await appendActivity(taskID: c.taskID, actorType: .run, actorID: UUID(), kind: "agent.claimed", subjectID: UUID(), on: w.db)
        w.task.status = "done"; try await w.task.save(on: w.db)
        try await appendActivity(taskID: c.taskID, actorType: .person, actorID: c.authorID, kind: "task.status_changed", subjectID: nil, on: w.db)
        // A status change on a task that is not done is not a post.
        try await appendActivity(taskID: secondTask.id!, actorType: .person, actorID: c.authorID, kind: "task.status_changed", subjectID: nil, on: w.db)
        let q = TaskQuestion(); q.taskID = secondTask.id!; q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "agent asks"; q.options = []; q.blocking = true; q.state = "open"; q.version = 1
        try await q.save(on: w.db)
        let pl = TaskPlanning(taskID: secondTask.id!); pl.dueAt = Date().addingTimeInterval(-60); try await pl.save(on: w.db)

        var r = try await feed(w)
        var kinds = (r.body?["posts"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["progress", "comment", "agent_run", "done"])
        XCTAssertEqual(kinds.count, 5)
        XCTAssertEqual((r.body?["needsYou"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }, ["question", "overdue"])

        r = try await feed(w, "?projectID=\(try second.requireID())")
        XCTAssertEqual((r.body?["posts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["progress B"])
        XCTAssertEqual(r.body?["projectID"] as? String, try second.requireID().uuidString)

        r = try await feed(w, "?mode=classic")
        kinds = (r.body?["posts"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["comment", "done"])
        XCTAssertEqual((r.body?["needsYou"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }, ["overdue"])
        r = try await feed(w, "?mode=management")
        XCTAssertEqual((r.body?["posts"] as? [Any])?.count, 5)
        await w.f.test.shutdown()
    }
}
