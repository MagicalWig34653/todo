// Single source for geometry and colours of the four drafts. render.mjs derives every file from it.
// Canvas 1024 × 1024; the motif stays inside the circle r = 409 around the centre (maskable and watch).
// Layers are listed back to front. Colours: [light, dark, tinted (grayscale)].

const rect = (x, y, w, h, r) => (fill) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" ${fill}/>`;
const circle = (cx, cy, r) => (fill) => `<circle cx="${cx}" cy="${cy}" r="${r}" ${fill}/>`;
const shape = (d) => (fill) => `<path d="${d}" ${fill}/>`;
const line = (d, width) => ({ d, width });
const all = (...parts) => (fill) => parts.map((part) => part(fill)).join('');

export const designs = [
  {
    dir: 'a-nest',
    bundle: 'Nest',
    title: 'A – Nest',
    idea: 'Projekte in Projekten: drei Ebenen, nach innen immer heller',
    background: [['#271D63', '#170F41'], ['#151129', '#080612'], ['#1F1F1F', '#0F0F0F']],
    layers: [
      { id: 'layer-1-project', name: 'Project', draw: rect(202, 202, 620, 620, 176), colors: ['#4C3DB8', '#342A78', '#6E6E6E'] },
      { id: 'layer-2-subproject', name: 'Subproject', draw: rect(258, 346, 420, 420, 120), colors: ['#9788F7', '#7C6DDB', '#ADADAD'] },
      { id: 'layer-3-task', name: 'Task', draw: rect(314, 484, 226, 226, 64), colors: ['#FFC531', '#FFBC1F', '#FFFFFF'] }
    ],
    favicon: {
      background: ['#4C3DB8', '#3B2F8F'],
      shapes: [
        { draw: rect(128, 192, 768, 704, 192), colors: ['#A99CFA', '#8F80EC'] },
        { draw: rect(256, 384, 384, 384, 96), colors: ['#FFC531', '#FFC531'] }
      ]
    }
  },
  {
    dir: 'b-schwung',
    bundle: 'Schwung',
    title: 'B – Schwung',
    idea: 'Ein gezeichnetes t für Todolino, dessen Fuß als Haken ausschwingt',
    background: [['#FF7650', '#E43F35'], ['#3B1812', '#190908'], ['#202020', '#0F0F0F']],
    layers: [
      { id: 'layer-1-crossbar', name: 'Crossbar', stroke: line('M 232 508 H 464', 100), colors: ['#FFE06B', '#FFD45C', '#B0B0B0'] },
      { id: 'layer-2-swing', name: 'Swing', stroke: line('M 336 396 V 636 C 336 712 372 752 424 752 C 466 752 494 730 520 690 L 770 272', 108), colors: ['#FFFFFF', '#FF8A68', '#F4F4F4'] }
    ],
    favicon: {
      background: ['#FF7650', '#E43F35'],
      shapes: [
        { stroke: line('M 168 504 H 448', 144), colors: ['#FFE06B', '#FFE06B'] },
        { stroke: line('M 304 360 V 668 C 304 780 352 832 424 832 C 480 832 516 800 548 744 L 852 200', 144), colors: ['#FFFFFF', '#FFFFFF'] }
      ]
    }
  },
  {
    dir: 'c-duett',
    bundle: 'Duett',
    title: 'C – Duett',
    idea: 'Mensch (Kreis) und Agent (Quadrat) haken gemeinsam ab',
    background: [['#12533F', '#093026'], ['#0D1C18', '#040B09'], ['#202020', '#0F0F0F']],
    layers: [
      { id: 'layer-1-human', name: 'Human', draw: circle(420, 420, 236), colors: ['#FF9F7C', '#E8805E', '#929292'] },
      { id: 'layer-2-agent', name: 'Agent', draw: rect(420, 420, 400, 400, 96), colors: ['#45DDA4', '#27B583', '#C4C4C4'] },
      { id: 'layer-3-shared', name: 'Shared', draw: shape('M 516 420 H 656 A 236 236 0 0 1 420 656 V 516 A 96 96 0 0 1 516 420 Z'), colors: ['#FFF4E2', '#FFEFD8', '#FFFFFF'] },
      { id: 'layer-4-check', name: 'Check', stroke: line('M 449 518 L 495 564 L 573 478', 52), colors: ['#0B3A2D', '#07261D', '#1C1C1C'] }
    ],
    favicon: {
      background: ['#12533F', '#093026'],
      shapes: [
        { draw: circle(384, 384, 320), colors: ['#FF9F7C', '#FF9F7C'] },
        { draw: rect(384, 384, 576, 576, 128), colors: ['#45DDA4', '#45DDA4'] },
        { draw: shape('M 512 384 H 704 A 320 320 0 0 1 384 704 V 512 A 128 128 0 0 1 512 384 Z'), colors: ['#FFF4E2', '#FFF4E2'] }
      ]
    }
  },
  {
    dir: 'd-bausteine',
    bundle: 'Bausteine',
    title: 'D – Bausteine',
    idea: 'Ein Haken aus Aufgabenblöcken, der nächste leuchtet',
    background: [['#FFD94F', '#FFBC1C'], ['#1E1C17', '#0D0C09'], ['#202020', '#0F0F0F']],
    layers: [
      { id: 'layer-1-done', name: 'Done blocks', draw: all(rect(179, 422, 180, 180, 30), rect(341, 584, 180, 180, 30), rect(503, 422, 180, 180, 30)), colors: ['#1C2646', '#FFCB33', '#BDBDBD'] },
      { id: 'layer-2-next', name: 'Next block', draw: rect(665, 260, 180, 180, 30), colors: ['#E9412B', '#FF6549', '#FFFFFF'] }
    ],
    favicon: {
      background: ['#FFD94F', '#FFBC1C'],
      darkBackground: ['#1E1C17', '#0D0C09'],
      shapes: [
        { draw: all(rect(128, 448, 192, 192, 16), rect(320, 640, 192, 192, 16), rect(512, 448, 192, 192, 16)), colors: ['#1C2646', '#FFCB33'] },
        { draw: rect(704, 256, 192, 192, 16), colors: ['#E9412B', '#FF6549'] }
      ]
    }
  }
];
