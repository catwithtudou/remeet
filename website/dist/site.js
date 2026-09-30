const panel = document.querySelector('#notch-panel');
if (panel) {
  const toggle = document.querySelector('#toggle-note');
  toggle.addEventListener('click', () => {
    const collapsed = panel.classList.toggle('collapsed');
    toggle.setAttribute('aria-expanded', String(!collapsed));
    toggle.setAttribute('aria-label', collapsed ? '展开回顾' : '收起回顾');
    toggle.textContent = collapsed ? '展开' : '收起';
  });
  const notes = [
    ['给自己一点空白，\n想法才有地方生长。', '示例 · 日常笔记'],
    ['先把问题看清楚，\n再急着寻找答案。', '示例 · 工作想法'],
    ['今天有什么小事，\n值得留给未来的自己？', '示例 · 留给自己的问题']
  ];
  let current = 0;
  document.querySelector('#next-note').addEventListener('click', () => {
    current = (current + 1) % notes.length;
    document.querySelector('#note-text').textContent = notes[current][0];
    document.querySelector('#note-source').textContent = notes[current][1];
  });
}
