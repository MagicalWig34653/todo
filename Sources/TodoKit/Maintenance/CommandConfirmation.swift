import Vapor

extension CommandContext {
    /// True if the operator confirmed with `--yes`/`-y`. ConsoleKit consumes that flag in its global signature (it answers
    /// confirmation prompts) and hands it over only as `console.confirmOverride`, so a command's own `@Flag(name: "yes")`
    /// never sees `true` when started as `App <command> --yes`. `flag` is kept for callers that run the command directly.
    func isConfirmed(_ flag: Bool) -> Bool { flag || console.confirmOverride == true }
}
