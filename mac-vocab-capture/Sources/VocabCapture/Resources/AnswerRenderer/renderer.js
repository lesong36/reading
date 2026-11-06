(() => {
  'use strict';
  if (!window.marked || !window.DOMPurify || !window.katex || !window.mermaid) return;
  const transcript = document.getElementById('transcript');
  const svgCache = new Map();
  let revision = 0;
  let mermaidQueue = Promise.resolve();
  let diagramID = 0;
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
    theme: 'neutral', htmlLabels: false, flowchart: { htmlLabels: false }, maxTextSize: 30000 });

  // Protect TeX before Markdown consumes its backslashes and underscores; leave code literal.
  function protectMath(source) {
    const math = [];
    let text = '';
    let index = 0;
    function escaped(position) {
      let count = 0;
      while (position > 0 && source.charCodeAt(--position) === 92) count++;
      return count % 2 === 1;
    }
    while (index < source.length) {
      // Code fences/spans must retain literal formula notation, including incomplete fences.
      if (index === 0 || source[index - 1] === '\n') {
        const fence = source.slice(index).match(/^ {0,3}(`{3,}|~{3,})[^\n]*(?:\n|$)/);
        if (fence) {
          const close = new RegExp('\n {0,3}' + fence[1][0] + '{' + fence[1].length + ',}[ \t]*(?:\n|$)');
          const rest = source.slice(index + fence[0].length);
          const match = close.exec('\n' + rest);
          const length = match ? fence[0].length + match.index + match[0].length - 1 : source.length - index;
          text += source.slice(index, index + length); index += length; continue;
        }
      }
      if (source[index] === '`') {
        const ticks = source.slice(index).match(/^`+/)[0];
        const end = source.indexOf(ticks, index + ticks.length);
        if (end >= 0) { text += source.slice(index, end + ticks.length); index = end + ticks.length; continue; }
      }
      const prefix = source.slice(index, index + 2);
      const display = prefix === '$$' || prefix === '\\[';
      const opening = display ? prefix : prefix === '\\(' ? prefix : source[index] === '$' ? '$' : null;
      if (opening && !escaped(index) && !(opening === '$' && /[A-Za-z0-9_]/.test(source[index - 1] || ''))) {
        const closing = opening === '\\[' ? '\\]' : opening === '\\(' ? '\\)' : opening;
        let end = source.indexOf(closing, index + opening.length);
        while (end >= 0 && escaped(end)) end = source.indexOf(closing, end + closing.length);
        const body = end >= 0 ? source.slice(index + opening.length, end) : '';
        const validInline = opening !== '$' || (body && !/^\s|\s$|\n/.test(body) && !/[A-Za-z0-9]/.test(source[end + 1] || ''));
        if (end >= 0 && validInline) {
          const original = source.slice(index, end + closing.length);
          const id = math.push({ source: body, display, original }) - 1;
          text += `MATHPLACEHOLDER${id}ENDTOKEN`; index = end + closing.length; continue;
        }
      }
      text += source[index++];
    }
    return { text, math };
  }

  function renderMarkdown(source, target) {
    const protectedText = protectMath(source);
    target.innerHTML = DOMPurify.sanitize(marked.parse(protectedText.text, { gfm: true, breaks: true,
      walkTokens(token) {
        if (token.type === 'code' && ['mermaid', 'math-grid', 'math-center-cut', 'math-cube-path', 'math-triangle-dissection', 'math-hexagon-partition', 'math-grid-route', 'math-rectangle-dissection'].includes(token.lang)) {
          const opening = token.raw.match(/^ {0,3}(`{3,}|~{3,})[^\n]*\n/);
          const closing = opening && new RegExp('\\n {0,3}' + opening[1][0] + '{' + opening[1].length + ',}[ \\t]*$');
          if (!closing || !closing.test(token.raw.trimEnd())) token.lang += '-pending';
        }
      }
    }), {
      ALLOWED_TAGS: ['p','br','strong','em','del','blockquote','pre','code','h1','h2','h3','h4','h5','h6',
        'ul','ol','li','hr','table','thead','tbody','tr','th','td','a','sup','sub'],
      ALLOWED_ATTR: ['class','start','colspan','rowspan','align','href','title'],
      ALLOW_DATA_ATTR: false
    });
    target.querySelectorAll('a[href]').forEach(link => {
      try {
        const url = new URL(link.getAttribute('href'));
        if (url.protocol !== 'https:' && url.protocol !== 'http:') link.removeAttribute('href');
      } catch (_) { link.removeAttribute('href'); }
    });
    const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(node => {
      if (node.parentElement.closest('code, pre')) return;
      const parts = node.textContent.split(/(MATHPLACEHOLDER\d+ENDTOKEN)/);
      if (parts.length === 1) return;
      const fragment = document.createDocumentFragment();
      parts.forEach(part => {
        const match = part.match(/^MATHPLACEHOLDER(\d+)ENDTOKEN$/);
        const math = match && protectedText.math[Number(match[1])];
        if (!math) { fragment.append(document.createTextNode(part)); return; }
        const span = document.createElement('span');
        try { katex.render(math.source, span, { displayMode: math.display, throwOnError: true,
          trust: false, strict: 'warn', maxExpand: 500, maxSize: 20 }); }
        catch (_) { span.className = 'math-error'; span.textContent = math.original; span.title = '公式未完成或格式有误，保留原文'; }
        fragment.append(span);
      });
      node.replaceWith(fragment);
    });
    target.querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div'); wrapper.className = 'table-scroll';
      table.replaceWith(wrapper); wrapper.append(table);
    });
  }

  function sanitizeSVG(svg) {
    const clean = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true },
      FORBID_TAGS: ['foreignObject','script','a','image'], FORBID_ATTR: ['href','xlink:href'] });
    return clean;
  }

  function enhanceMermaid(target, currentRevision) {
    target.querySelectorAll('pre > code.language-mermaid').forEach(code => {
      const source = code.textContent;
      const box = document.createElement('div'); box.className = 'diagram';
      box.setAttribute('aria-label', 'Mermaid 图表');
      const fallback = document.createElement('pre'); fallback.textContent = source; box.append(fallback);
      code.parentElement.replaceWith(box);
      if (svgCache.has(source)) { box.innerHTML = svgCache.get(source); return; }
      mermaidQueue = mermaidQueue.catch(() => {}).then(async () => {
        if (currentRevision !== revision || !box.isConnected) return;
        try {
          if (source.length > 30000 || /%%\s*\{|^\s*click\s/im.test(source)) throw new Error('unsupported directive');
          const result = await mermaid.render(`answerDiagram${++diagramID}`, source);
          const svg = sanitizeSVG(result.svg);
          if (!svg.includes('<svg')) throw new Error('empty diagram');
          svgCache.set(source, svg);
          if (svgCache.size > 32) svgCache.delete(svgCache.keys().next().value);
          if (currentRevision === revision && box.isConnected) {
            const follow = document.documentElement.scrollHeight - window.innerHeight - window.scrollY < 75;
            box.innerHTML = svg;
            if (follow) window.scrollTo(0, document.documentElement.scrollHeight);
          }
        } catch (_) {
          if (currentRevision !== revision || !box.isConnected) return;
          const note = document.createElement('div'); note.className = 'render-error';
          note.textContent = '图表未完成或格式有误，已保留原始内容。'; box.prepend(note);
        }
      });
    });
  }

  // A bounded cell partition, not model-supplied SVG or executable drawing code.
  function checkedGridPlan(source) {
    function require(condition, message) { if (!condition) throw new Error(message); }
    require(source.length <= 30000, '数据超出范围');
    const plan = JSON.parse(source);
    require(plan && !Array.isArray(plan) && typeof plan === 'object' &&
      Object.keys(plan).length === 5 &&
      Object.keys(plan).every(key => ['title','unitWidth','unitHeight','source','target'].includes(key)), '字段不完整或不受支持');
    require(typeof plan.title === 'string' && plan.title.trim().length > 0 &&
      plan.title.length <= 120 && !/[\u0000-\u001f\u007f]/.test(plan.title), '标题无效');
    const units = ['unitWidth', 'unitHeight'].map(key => {
      const value = plan[key];
      require(typeof value === 'number' && Number.isFinite(value) && value > 0 && value <= 1000,
        '每格长宽须为正数且不超过1000');
      const fixed = Math.round(value * 1000000);
      require(fixed > 0 && Math.abs(fixed / 1000000 - value) <= 1e-12 * Math.max(1, value),
        '每格长宽最多支持六位小数');
      return fixed;
    });
    function board(rows) {
      require(Array.isArray(rows) && rows.length >= 1 && rows.length <= 16 &&
        Array.isArray(rows[0]) && rows[0].length >= 1 && rows[0].length <= 16, '网格须在16行16列以内');
      const width = rows[0].length;
      const pieces = new Map();
      rows.forEach((row, y) => {
        require(Array.isArray(row) && row.length === width, '每行格数须相同');
        row.forEach((id, x) => {
          require(typeof id === 'string' && id.length <= 12 && !/[\u0000-\u001f\u007f]/.test(id) &&
            (id === '' || id.trim() === id), '块号须为不超过12字的非空白文本');
          if (id !== '') {
            if (!pieces.has(id)) pieces.set(id, []);
            pieces.get(id).push([x, y]);
          }
        });
      });
      require(pieces.size > 0 && pieces.size <= 16, '分块数量须为1至16');
      pieces.forEach(cells => {
        const keys = new Set(cells.map(([x,y]) => `${x},${y}`));
        const seen = new Set([`${cells[0][0]},${cells[0][1]}`]);
        const queue = [cells[0]];
        for (let i = 0; i < queue.length; i++) {
          const [x,y] = queue[i];
          [[x-1,y],[x+1,y],[x,y-1],[x,y+1]].forEach(([a,b]) => {
            const key = `${a},${b}`;
            if (keys.has(key) && !seen.has(key)) { seen.add(key); queue.push([a,b]); }
          });
        }
        require(seen.size === cells.length, '每块必须共边连通');
      });
      return { rows, width, height: rows.length, pieces };
    }
    const original = board(plan.source), target = board(plan.target);
    require(original.pieces.size === target.pieces.size &&
      [...original.pieces.keys()].every(id => target.pieces.has(id)), '两图块号须完全对应');
    function normalized(cells) {
      const minX = Math.min(...cells.map(p => p[0])), minY = Math.min(...cells.map(p => p[1]));
      return cells.map(([x,y]) => [x-minX,y-minY]).sort((a,b) => a[0]-b[0] || a[1]-b[1])
        .map(p => p.join(',')).join(';');
    }
    original.pieces.forEach((cells, id) => {
      const other = target.pieces.get(id);
      require(cells.length === other.length, '对应块格数不同');
      const expected = normalized(other);
      const signs = [[1,1],[-1,1],[1,-1],[-1,-1]];
      const orientations = signs.map(([a,b]) => cells.map(([x,y]) => [a*x,b*y]));
      // A quarter-turn of an anisotropic cell does not fit the unchanged cell axes.
      if (units[0] === units[1]) signs.forEach(([a,b]) => orientations.push(cells.map(([x,y]) => [a*y,b*x])));
      require(orientations.some(shape => normalized(shape) === expected),
        '对应块不是同形刚性移动；长方格不能当作正方格旋转');
    });
    return { ...plan, original, destination: target, ids: [...original.pieces.keys()].sort() };
  }

  function gridSVG(plan) {
    const ns = 'http://www.w3.org/2000/svg';
    function node(tag, attributes, text) {
      const element = document.createElementNS(ns, tag);
      Object.entries(attributes || {}).forEach(([key,value]) => element.setAttribute(key, String(value)));
      if (text !== undefined) element.textContent = text;
      return element;
    }
    const partitionOnly = JSON.stringify(plan.source) === JSON.stringify(plan.target);
    const boards = partitionOnly ? [plan.original] : [plan.original, plan.destination];
    const maxWidth = Math.max(...boards.map(b => b.width * plan.unitWidth));
    const maxHeight = Math.max(...boards.map(b => b.height * plan.unitHeight));
    const scale = Math.min(340 / maxWidth, 340 / maxHeight);
    const cellWidth = plan.unitWidth * scale, cellHeight = plan.unitHeight * scale;
    const height = maxHeight * scale + 115;
    const svg = node('svg', { viewBox: `0 0 ${partitionOnly ? 440 : 880} ${height}`, role: 'img',
      class: partitionOnly ? 'grid-partition-only' : 'grid-reassembly',
      'aria-label': plan.title, 'data-unit-width': plan.unitWidth, 'data-unit-height': plan.unitHeight });
    svg.append(node('title', {}, plan.title));
    const colors = ['#dce9fa','#f8e2bd','#dceedd','#eddff5','#f5dfe4','#d4eeee','#f2eccb','#e4e4f6'];
    boards.forEach((board, index) => {
      const width = board.width * cellWidth, boardHeight = board.height * cellHeight;
      const left = 220 + index * 440 - width / 2, top = 46 + maxHeight * scale - boardHeight;
      const group = node('g', { class: 'grid-board', 'data-board': index ? 'target' : 'source' });
      group.append(node('text', { x: left + width/2, y: 24, 'text-anchor': 'middle', class: 'grid-heading' },
        partitionOnly ? '分块方案（实线为分界）' : index ? '拼后（实线为接缝）' : '原图（实线为切线）'));
      function label(x, y, number) {
        if (cellWidth < 10 || cellHeight < 10) return;
        group.append(node('text', { x: left+x*cellWidth, y: top+y*cellHeight,
          'text-anchor': 'middle', 'dominant-baseline': 'central', class: 'grid-cell-label',
          'font-size': Math.min(16, cellWidth*.48, cellHeight*.55) }, String(number+1)));
      }
      const edges = new Map();
      function edge(key, points, id) {
        if (!edges.has(key)) edges.set(key, { points, ids: [] });
        edges.get(key).ids.push(id);
      }
      board.rows.forEach((row,y) => row.forEach((id,x) => {
        if (id === '') return;
        const number = plan.ids.indexOf(id);
        group.append(node('rect', { x: left+x*cellWidth, y: top+y*cellHeight,
          width: cellWidth, height: cellHeight, fill: colors[number % colors.length], 'data-piece': id }));
        if (!partitionOnly) label(x+.5, y+.5, number);
        edge(`h${x},${y}`, [x,y,x+1,y], id); edge(`h${x},${y+1}`, [x,y+1,x+1,y+1], id);
        edge(`v${x},${y}`, [x,y,x,y+1], id); edge(`v${x+1},${y}`, [x+1,y,x+1,y+1], id);
      }));
      if (partitionOnly) board.pieces.forEach((cells, id) => {
        const center = cells.reduce(([a,b],[x,y]) => [a+x,b+y], [0,0]).map(v => v/cells.length);
        const nearest = cells.reduce((best,cell) =>
          (cell[0]-center[0])**2+(cell[1]-center[1])**2 <
          (best[0]-center[0])**2+(best[1]-center[1])**2 ? cell : best, cells[0]);
        label(nearest[0]+.5, nearest[1]+.5, plan.ids.indexOf(id));
      });
      edges.forEach(({points,ids}) => {
        const [x1,y1,x2,y2] = points;
        const seam = ids.length === 1 || ids[0] !== ids[1];
        group.append(node('line', { x1: left+x1*cellWidth, y1: top+y1*cellHeight,
          x2: left+x2*cellWidth, y2: top+y2*cellHeight,
          stroke: seam ? '#26313d' : '#7e8c99', 'stroke-width': seam ? 2 : .7,
          'stroke-dasharray': seam ? 'none' : '3 3', 'data-seam': seam ? 'true' : 'false' }));
      });
      group.append(node('text', { x: left+width/2, y: top+boardHeight+25,
        'text-anchor': 'middle', class: 'grid-dimensions' },
        `${Number((board.width*plan.unitWidth).toFixed(6))} × ${Number((board.height*plan.unitHeight).toFixed(6))}`));
      svg.append(group);
    });
    return svg;
  }

  function enhanceGridRoutes(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-grid-route').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent, box = document.createElement('div'); box.className = 'diagram math-grid-route';
      try {
        if (source.length > 10000) throw new Error('数据超出范围');
        const p = JSON.parse(source), keys = ['width','height','points','stars'];
        if (!p || typeof p !== 'object' || Array.isArray(p) || Object.keys(p).length !== 4 || !Object.keys(p).every(k => keys.includes(k))) throw new Error('字段不完整或不受支持');
        if (![p.width,p.height].every(v => Number.isInteger(v) && v >= 1 && v <= 8)) throw new Error('网格尺寸无效');
        const validPoint = a => Array.isArray(a) && a.length === 2 && Number.isInteger(a[0]) && Number.isInteger(a[1]) && a[0] >= 0 && a[0] <= p.width && a[1] >= 0 && a[1] <= p.height;
        if (!Array.isArray(p.points) || p.points.length < 2 || p.points.length > 100 || !p.points.every(validPoint) || !Array.isArray(p.stars) || p.stars.length > 32 || !p.stars.every(validPoint) || !p.points.slice(1).every((v,i) => Math.abs(v[0]-p.points[i][0])+Math.abs(v[1]-p.points[i][1]) === 1)) throw new Error('路径或标记无效');
        const ns = 'http://www.w3.org/2000/svg', node = (tag, attrs, text) => { const e = document.createElementNS(ns,tag); Object.entries(attrs).forEach(([k,v]) => e.setAttribute(k,String(v))); if (text !== undefined) e.textContent=text; return e; };
        const scale=48, pad=28, svg=node('svg',{viewBox:`0 0 ${p.width*scale+2*pad} ${p.height*scale+2*pad}`,role:'img','aria-label':'格线路线示意'});
        for (let x=0;x<=p.width;x++) svg.append(node('line',{x1:pad+x*scale,y1:pad,x2:pad+x*scale,y2:pad+p.height*scale,stroke:'#a9b5bf','stroke-width':1}));
        for (let y=0;y<=p.height;y++) svg.append(node('line',{x1:pad,y1:pad+y*scale,x2:pad+p.width*scale,y2:pad+y*scale,stroke:'#a9b5bf','stroke-width':1}));
        svg.append(node('polyline',{points:p.points.map(([x,y])=>`${pad+x*scale},${pad+y*scale}`).join(' '),fill:'none',stroke:'#1769aa','stroke-width':4,'stroke-linecap':'round','stroke-linejoin':'round'}));
        p.stars.forEach(([x,y])=>svg.append(node('text',{x:pad+x*scale,y:pad+y*scale+5,'text-anchor':'middle',fill:'#ad5b00','font-size':19},'★')));
        const [x,y]=p.points[0]; svg.append(node('circle',{cx:pad+x*scale,cy:pad+y*scale,r:5,fill:'#167345'}));
        const note=document.createElement('div'); note.textContent='路线示意：绿色圆点为起点，星号为目标；请核对原题和路线。'; box.append(svg,note);
      } catch (error) { const note=document.createElement('div'); note.className='render-error'; note.textContent='路线图未生成：数据不完整或格式不符。已保留原始内容。'; const fallback=document.createElement('pre'); fallback.textContent=source; box.append(note,fallback); }
      code.parentElement.replaceWith(box);
    });
  }

  function enhanceMathGrids(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-grid').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent;
      const box = document.createElement('div'); box.className = 'diagram math-grid';
      try {
        const plan = checkedGridPlan(source);
        const heading = document.createElement('div'); heading.className = 'grid-title'; heading.textContent = plan.title;
        const legend = document.createElement('div'); legend.className = 'grid-legend';
        legend.textContent = plan.ids.map((id,i) => `${i+1}：${id}`).join('　');
        const note = document.createElement('div'); note.className = 'grid-note';
        note.textContent = `每格横${plan.unitWidth}、纵${plan.unitHeight}，长度沿用题目单位。仅核对输入的分块与同形关系，题意和答案仍待核验。`;
        box.append(heading, gridSVG(plan), legend, note);
      } catch (error) {
        const note = document.createElement('div'); note.className = 'render-error';
        note.textContent = `分块图未生成：${error instanceof SyntaxError ? 'JSON格式不完整或有误' : error.message}。已保留原始内容。`;
        const fallback = document.createElement('pre'); fallback.textContent = source; box.append(note, fallback);
      }
      code.parentElement.replaceWith(box);
    });
  }


  // Only bounded rectangle data is accepted; all SVG nodes and labels are created locally.
  function checkedCenterCut(source) {
    function require(ok, message) { if (!ok) throw new Error(message); }
    function keys(value, expected) {
      return value && typeof value === 'object' && !Array.isArray(value) &&
        Object.keys(value).length === expected.length && Object.keys(value).every(k => expected.includes(k));
    }
    require(source.length <= 2000, '数据超出范围');
    const p = JSON.parse(source);
    require(keys(p, ['title','outerWidth','outerHeight','hole']), '字段不完整或不受支持');
    require(typeof p.title === 'string' && p.title.trim().length > 0 && p.title.length <= 120 &&
      !/[<>\u0000-\u001f\u007f]/.test(p.title), '标题须为纯文本');
    require(keys(p.hole, ['x','y','width','height']), '孔字段不完整或不受支持');
    const h = p.hole;
    [p.outerWidth,p.outerHeight,h.x,h.y,h.width,h.height].forEach(v =>
      require(typeof v === 'number' && Number.isFinite(v) && v >= .001 && v <= 1000, '数值须在0.001至1000之间'));
    require(h.x+h.width < p.outerWidth && h.y+h.height < p.outerHeight, '孔须严格位于外框内部');
    require(Math.max(p.outerWidth,p.outerHeight)/Math.min(p.outerWidth,p.outerHeight) <= 20,
      '外框长宽比例超出范围');
    return p;
  }

  function centerCutSVG(p) {
    const ns = 'http://www.w3.org/2000/svg';
    function node(tag, attrs, text) {
      const el = document.createElementNS(ns, tag);
      Object.entries(attrs || {}).forEach(([k,v]) => el.setAttribute(k, String(v)));
      if (text !== undefined) el.textContent = text;
      return el;
    }
    const h = p.hole, o = [p.outerWidth/2,p.outerHeight/2], c = [h.x+h.width/2,h.y+h.height/2];
    let d = [c[0]-o[0],c[1]-o[1]];
    if (d[0] === 0 && d[1] === 0) d = [1,0];
    // Slab intersection gives exact endpoints, including vertical and horizontal lines.
    function interval(x,y,w,height) {
      let lo = -Infinity, hi = Infinity;
      [[x,x+w],[y,y+height]].forEach(([a,b],i) => {
        if (d[i] !== 0) { const t1=(a-o[i])/d[i],t2=(b-o[i])/d[i]; lo=Math.max(lo,Math.min(t1,t2)); hi=Math.min(hi,Math.max(t1,t2)); }
      });
      return [lo,hi];
    }
    const outer = interval(0,0,p.outerWidth,p.outerHeight), inner = interval(h.x,h.y,h.width,h.height);
    const scale = 360/Math.max(p.outerWidth,p.outerHeight), left = 70, top = 42;
    const point = t => [o[0]+t*d[0],o[1]+t*d[1]];
    const px = x => left+x*scale, py = y => top+y*scale;
    const svg = node('svg', {viewBox:`0 0 ${p.outerWidth*scale+140} ${p.outerHeight*scale+90}`,role:'img','aria-label':`${p.title}（示意图）`});
    svg.append(node('title', {}, `${p.title}（示意图，不表示实际长度）`));
    function rect(x,y,w,height,kind,fill) {
      svg.append(node('rect',{x:px(x),y:py(y),width:w*scale,height:height*scale,fill,stroke:'#52606d','stroke-width':2,'data-geometry':kind}));
    }
    rect(0,0,p.outerWidth,p.outerHeight,'outer','#edf0f3');
    rect(h.x,h.y,h.width,h.height,'hole','#fff');
    function line(a,b,kind,stroke,dash,width) {
      svg.append(node('line',{x1:px(a[0]),y1:py(a[1]),x2:px(b[0]),y2:py(b[1]),stroke,'stroke-width':width,'stroke-dasharray':dash,'data-cut':kind}));
    }
    line([h.x,h.y],[h.x+h.width,h.y+h.height],'aid','#aeb8c2','4 5',1);
    line([h.x+h.width,h.y],[h.x,h.y+h.height],'aid','#aeb8c2','4 5',1);
    line(point(outer[0]),point(inner[0]),'paper','#c83535','none',3);
    line(point(inner[1]),point(outer[1]),'paper','#c83535','none',3);
    line(point(inner[0]),point(inner[1]),'empty','#c83535','7 6',2);
    function label(pos,text,dx,dy,kind) {
      svg.append(node('circle',{cx:px(pos[0]),cy:py(pos[1]),r:3,fill:'#26313d','data-point':kind}));
      svg.append(node('text',{x:px(pos[0])+dx,y:py(pos[1])+dy,class:'center-cut-label'},text));
    }
    label(point(outer[0]),'A',-22,-10,'A'); label(point(outer[1]),'B',10,22,'B');
    label(o,'O',10,-12,'O'); label(c,'C',10,22,'C');
    return svg;
  }

  function enhanceCenterCuts(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-center-cut').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent;
      const box = document.createElement('div'); box.className = 'diagram math-center-cut';
      try {
        const plan = checkedCenterCut(source);
        const heading = document.createElement('div'); heading.className = 'center-cut-title'; heading.textContent = `${plan.title}（示意图）`;
        const note = document.createElement('div'); note.className = 'center-cut-note';
        note.textContent = '示意图，不表示实际长度，也不增加题目条件。O为外框中心，C为孔中心；红实线为纸上切口，红虚线经过空孔，浅虚线辅助定位孔中心。';
        box.append(heading,centerCutSVG(plan),note);
      } catch (error) {
        const note = document.createElement('div'); note.className = 'render-error';
        note.textContent = `中心切割图未生成：${error instanceof SyntaxError ? 'JSON格式不完整或有误' : error.message}。已保留原始内容。`;
        const fallback = document.createElement('pre'); fallback.textContent = source; box.append(note,fallback);
      }
      code.parentElement.replaceWith(box);
    });
  }

  // Fixed, source-specific construction. The model supplies only the proved case id.
  function enhanceRectangleDissections(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-rectangle-dissection').forEach(code => {
      if (currentRevision !== revision) return;
      const box = document.createElement('div'); box.className = 'diagram math-rectangle-dissection';
      try {
        if (!/^\s*\{\s*"case"\s*:\s*"404-e12"\s*\}\s*$/.test(code.textContent)) throw new Error('仅支持已核验的404-E12构造');
        const ns = 'http://www.w3.org/2000/svg', W = 520, H = 430, svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('role', 'img');
        svg.setAttribute('aria-label', '16×9长方形三块平移拼成12×12正方形');
        const node = (tag, attrs) => { const e=document.createElementNS(ns,tag); Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,String(v))); svg.append(e); return e; };
        const colors = ['#dbeafe','#fce7cf','#d7f1de'];
        const draw = (origin, scale, polys, title) => {
          const ox=origin[0], oy=origin[1];
          node('text',{x:ox,y:oy-14,'font-size':16,'font-weight':'600','text-anchor':'middle'}).textContent=title;
          polys.forEach((p,i)=>node('polygon',{points:p.map(([x,y])=>`${ox+x*scale},${oy+y*scale}`).join(' '),fill:colors[i],stroke:'#34495e','stroke-width':1.5,'data-piece':String(i+1)}));
          node('rect',{x:ox,y:oy,width:(title.includes('原')?16:12)*scale,height:(title.includes('原')?9:12)*scale,fill:'none',stroke:'#26313d','stroke-width':2,'data-outline':title});
        };
        draw([30,55], 20, [[ [0,0],[4,0],[4,3] ], [ [0,0],[4,3],[12,9],[0,9] ], [ [4,0],[16,0],[16,9],[12,9],[4,3] ]], '原图16×9');
        draw([210,55], 25, [[ [8,9],[12,9],[12,12] ], [ [0,3],[4,6],[12,12],[0,12] ], [ [0,0],[12,0],[12,9],[8,9],[0,3] ]], '拼成12×12');
        const note=node('text',{x:260,y:400,'font-size':13,'text-anchor':'middle'}); note.textContent='三块均只平移；颜色编号对应同一块，边界无重叠、无缺口';
        box.append(svg); code.parentElement.replaceWith(box);
      } catch (error) {
        const note = document.createElement('div'); note.className='render-error'; note.textContent=`剪拼图未生成：${error.message}。已保留原始内容。`;
        const fallback=document.createElement('pre'); fallback.textContent=code.textContent; box.append(note,fallback); code.parentElement.replaceWith(box);
      }
    });
  }

  // Two independently checked fixed constructions; the model supplies only
  // the case number, never markup or arbitrary coordinates.
  // Regular hexagon only. The model selects a proved construction; it cannot
  // supply coordinates, markup, extra cuts or a distorted source outline.
  function enhanceHexagonPartitions(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-hexagon-partition').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent, box = document.createElement('div');
      box.className = 'diagram math-hexagon-partition';
      try {
        if (!/^\s*\{\s*"sides"\s*:\s*[345]\s*\}\s*$/.test(source)) throw new Error('仅支持每块3、4或5条边的正六边形构造');
        const sides = JSON.parse(source).sides;
        const vertices = [[-1,1],[-2,0],[-1,-1],[1,-1],[2,0],[1,1]], center = [0,0];
        const mid = i => vertices[i].map((v,k) => (v + vertices[(i+1)%6][k])/2);
        const pieces = sides === 3 ? vertices.map((v,i) => [center,v,vertices[(i+1)%6]])
          : [0,2,4].map(i => sides === 4 ? [center,vertices[i],vertices[(i+1)%6],vertices[(i+2)%6]]
            : [center,mid(i),vertices[(i+1)%6],vertices[(i+2)%6],mid((i+2)%6)]);
        const cuts = sides === 3 ? [0,1,2].map(i => [vertices[i],vertices[i+3]])
          : [0,2,4].map(i => [center,sides === 4 ? vertices[i] : mid(i)]);
        const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns,'svg');
        svg.setAttribute('viewBox','0 0 500 420'); svg.setAttribute('role','img');
        svg.setAttribute('aria-label', sides === 3 ? '正六边形用三条完整对角线分六个全等三角形' : `正六边形分三个全等${sides === 4 ? '四' : '五'}边形`);
        svg.style.maxWidth = '500px'; svg.style.width = '100%';
        const pixel = ([x,y]) => [250+x*95,200-y*95*Math.sqrt(3)];
        const node = (tag, attrs) => { const e=document.createElementNS(ns,tag); Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,String(v)));svg.append(e);return e; };
        const colours=['#dbeafe','#fce7cf','#d7f1de','#eee2f9','#f9dfdf','#d5eff0'];
        pieces.forEach((piece,i)=>node('polygon', {points:piece.map(p=>pixel(p).join(',')).join(' '),fill:colours[i],stroke:'#34495e','stroke-width':1,'data-piece':i+1}));
        cuts.forEach(([a,b],i)=>{const [x1,y1]=pixel(a),[x2,y2]=pixel(b);node('line',{x1,y1,x2,y2,stroke:'#174d87','stroke-width':3,'data-cut':i+1});});
        const label=(name,p)=>{const [x,y]=pixel(p);node('circle',{cx:x,cy:y,r:2,fill:'#24384e','data-point':name});const t=node('text',{x:x+(p[0]<0?-14:12),y:y+(p[1]>0?-12:18),'text-anchor':'middle','font-size':16});t.textContent=name;};
        vertices.forEach((p,i)=>label('ABCDEF'[i],p)); label('O',center);
        if(sides===5)[0,2,4].forEach((i,j)=>label(['M','N','P'][j],mid(i)));
        const note=document.createElement('div');note.textContent=sides===3 ? '画AD、BE、CF三条完整线段；六块绕O转60°重合。' : sides===4 ? '画OA、OC、OE；三块绕O转120°重合。' : 'M、N、P分别为AB、CD、EF中点；画OM、ON、OP，三块绕O转120°重合。';
        box.append(svg,note);
      } catch(error) {
        const note=document.createElement('div');note.className='render-error';note.textContent=`正六边形等分图未生成：${error.message}。已保留原始内容。`;
        const fallback=document.createElement('pre');fallback.textContent=source;box.append(note,fallback);
      }
      code.parentElement.replaceWith(box);
    });
  }

  function enhanceTriangleDissections(target, currentRevision) {
    const plans = {
      5: [[[0,0],[1,0],[1,2]],[[1,0],[3,0],[3,1]],[[1,0],[3,1],[1,1]],[[1,2],[1,1],[3,1]],[[3,0],[3,1],[5,0]]],
      13: [[[0,0],[2,0],[2,3]],[[2,0],[4,0],[4,3]],[[2,0],[2,3],[4,3]],[[2,3],[4,3],[4,6]],[[4,4],[4,6],[7,4]],[[4,2],[4,4],[7,2]],[[4,4],[7,4],[7,2]],[[7,2],[7,4],[10,2]],[[4,0],[4,2],[7,0]],[[4,2],[7,2],[7,0]],[[7,0],[7,2],[10,0]],[[7,2],[10,2],[10,0]],[[10,0],[10,2],[13,0]]]
    };
    target.querySelectorAll('pre > code.language-math-triangle-dissection').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent, box = document.createElement('div');
      box.className = 'diagram math-triangle-dissection';
      try {
        if (/^\s*\{\s*"case"\s*:\s*"404-e03"\s*\}\s*$/.test(source)) {
          const cells = [
            [[0,0],[1,1],[2,0]],[[1,1],[2,0],[3,1]],[[2,0],[3,1],[4,0]],[[3,1],[4,0],[5,1]],[[4,0],[5,1],[6,0]],[[5,1],[6,0],[7,1]],[[6,0],[7,1],[8,0]],[[7,1],[8,0],[9,1]],[[8,0],[9,1],[10,0]],[[9,1],[10,0],[11,1]],[[10,0],[11,1],[12,0]],
            [[1,1],[2,2],[3,1]],[[2,2],[3,1],[4,2]],[[3,1],[4,2],[5,1]],[[4,2],[5,1],[6,2]],[[5,1],[6,2],[7,1]],[[6,2],[7,1],[8,2]],[[7,1],[8,2],[9,1]],[[8,2],[9,1],[10,2]],[[9,1],[10,2],[11,1]],
            [[2,2],[3,3],[4,2]],[[3,3],[4,2],[5,3]],[[4,2],[5,3],[6,2]],[[3,3],[4,4],[5,3]]
          ];
          const groups = [[0,1,2,3,4,13],[5,14,15,16,17,18],[6,7,8,9,10,19],[11,12,20,21,22,23]];
          const groupOf = new Map(groups.flatMap((g, i) => g.map(n => [n, i])));
          const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
          svg.setAttribute('viewBox', '0 0 500 250'); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', '图4-13沿格线分成四个全等部分');
          const colours = ['#eadcf2','#dce9f8','#f8e0c5','#d9efdc'];
          const pixel = ([x,y]) => [35+x*35,220-y*35];
          cells.forEach((triangle, index) => { const p = document.createElementNS(ns, 'polygon'); p.setAttribute('points', triangle.map(v => pixel(v).join(',')).join(' ')); p.setAttribute('fill', colours[groupOf.get(index)]); p.setAttribute('stroke', '#91a2b5'); p.setAttribute('stroke-width', '1'); p.setAttribute('data-piece', String(groupOf.get(index)+1)); svg.append(p); });
          groups.forEach((group, index) => group.forEach(cell => { const p = svg.querySelector(`polygon[data-piece="${index+1}"][data-cell="${cell}"]`); if (p) p.setAttribute('data-cell', String(cell)); }));
          const note = document.createElement('div'); note.textContent = '图4-13固定来源构造：24个小三角形，四块各6格，允许翻面后全等。'; box.append(svg, note); code.parentElement.replaceWith(box); return;
        }
        if (!/^\s*\{\s*"pieces"\s*:\s*(?:5|13)\s*\}\s*$/.test(source)) throw new Error('仅支持预设的5块或13块构造');
        const count = JSON.parse(source).pieces, triangles = plans[count];
        const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
        const scale = count === 5 ? 65 : 28, height = count === 5 ? 180 : 200;
        svg.setAttribute('viewBox', `0 0 ${count === 5 ? 350 : 390} ${height}`);
        svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', `${count}个全等三角形分割示意图`);
        const colours = ['#dbeafe','#fce7cf','#d7f1de','#eee2f9','#f9dfdf','#d5eff0','#fcebc4','#dfebce','#ecddea','#d6e0f6','#f4e1d1','#d4ebe2','#f1e8c9'];
        triangles.forEach((triangle, index) => {
          const polygon = document.createElementNS(ns, 'polygon');
          polygon.setAttribute('points', triangle.map(([x,y]) => `${10+x*scale},${height-10-y*scale}`).join(' '));
          polygon.setAttribute('fill', colours[index]); polygon.setAttribute('stroke', '#34495e'); polygon.setAttribute('stroke-width', '2');
          polygon.setAttribute('data-piece', String(index+1)); svg.append(polygon);
          const label = document.createElementNS(ns, 'text');
          label.setAttribute('x', String(10+triangle.reduce((a,p)=>a+p[0],0)*scale/3));
          label.setAttribute('y', String(height-10-triangle.reduce((a,p)=>a+p[1],0)*scale/3));
          label.setAttribute('text-anchor', 'middle'); label.setAttribute('dominant-baseline', 'central');
          label.textContent = String(index+1); svg.append(label);
        });
        const note = document.createElement('div');
        note.textContent = `${count}个全等三角形的预设构造；请确认题目允许自行选择大三角形。`;
        box.append(svg, note);
      } catch (error) {
        const note = document.createElement('div'); note.className = 'render-error';
        note.textContent = `三角形分割图未生成：${error.message}。已保留原始内容。`;
        const fallback = document.createElement('pre'); fallback.textContent = source; box.append(note, fallback);
      }
      code.parentElement.replaceWith(box);
    });
  }

  function enhanceCubePaths(target, currentRevision) {
    target.querySelectorAll('pre > code.language-math-cube-path').forEach(code => {
      if (currentRevision !== revision) return;
      const source = code.textContent, box = document.createElement('div');
      box.className = 'diagram math-cube-path';
      try {
        if (source.length > 1000) throw new Error('数据超出范围');
        // This tiny closed format needs exactly two fields. JSON.parse alone
        // silently accepts duplicate keys, unlike the tool-side validator.
        const jsonString = '"(?:[^"\\\\\\x00-\\x1f]|\\\\(?:["\\\\/bfnrt]|u[0-9a-fA-F]{4}))*"';
        const fieldTitle = `"title"\\s*:\\s*${jsonString}`;
        const fieldEdge = '"edge"\\s*:\\s*[0-5]';
        const shape = new RegExp(`^\\s*\\{\\s*(?:${fieldTitle}\\s*,\\s*${fieldEdge}|${fieldEdge}\\s*,\\s*${fieldTitle})\\s*\\}\\s*$`);
        if (!shape.test(source)) throw new Error('字段不完整或重复');
        const p = JSON.parse(source);
        if (!p || Array.isArray(p) || Object.keys(p).sort().join(',') !== 'edge,title' ||
          typeof p.title !== 'string' || !p.title.trim() || p.title.length > 120 ||
          /[<>\u0000-\u001f\u007f]/.test(p.title) || !Number.isInteger(p.edge) || p.edge < 0 || p.edge > 5)
          throw new Error('标题或路线编号无效');
        const ns = 'http://www.w3.org/2000/svg';
        const node = (tag, attrs, text) => { const e = document.createElementNS(ns, tag); Object.entries(attrs).forEach(([k,v]) => e.setAttribute(k,String(v))); if (text !== undefined) e.textContent=text; return e; };
        const svg = node('svg', {viewBox:'0 0 650 270', role:'img', 'aria-label':p.title});
        svg.append(node('title',{},p.title));
        // Oblique projection of cube; edges are chosen by ordered A-face/B-face pairs.
        const project = ([x,y,z]) => [80+120*x+45*y, 195-120*z-35*y];
        const lines = [[[0,0,0],[1,0,0]],[[0,0,0],[0,1,0]],[[0,0,0],[0,0,1]],[[1,0,0],[1,1,0]],[[1,0,0],[1,0,1]],[[0,1,0],[1,1,0]],[[0,1,0],[0,1,1]],[[0,0,1],[1,0,1]],[[0,0,1],[0,1,1]],[[1,1,1],[1,1,0]],[[1,1,1],[1,0,1]],[[1,1,1],[0,1,1]]];
        const line = (a,b,color,width,dash='none') => svg.append(node('line',{x1:a[0],y1:a[1],x2:b[0],y2:b[1],stroke:color,'stroke-width':width,'stroke-dasharray':dash}));
        const hiddenVertex = p => p[0] === 0 && p[1] === 1 && p[2] === 0;
        lines.forEach(([a,b])=>line(project(a),project(b),'#758493',1.5,
          hiddenVertex(a) || hiddenVertex(b) ? '5 4' : 'none'));
        const pairs=[[0,1],[0,2],[1,0],[1,2],[2,0],[2,1]], [i,j]=pairs[p.edge], mid=[.5,.5,.5]; mid[i]=0;mid[j]=1;
        line(project([0,0,0]),project(mid),'#c83535',3, i === 0 || i === 2 ? '7 4' : 'none');
        line(project(mid),project([1,1,1]),'#c83535',3, j === 1 ? '7 4' : 'none');
        svg.append(node('text',{x:60,y:220},'A'));svg.append(node('text',{x:250,y:35},'B'));
        // Two unit faces unfolded into a 2×1 rectangle. Crossing is the shared-edge midpoint.
        svg.append(node('rect',{x:350,y:70,width:240,height:120,fill:'#f4f7fa',stroke:'#52606d','stroke-width':2}));
        line([470,70],[470,190],'#52606d',2);line([350,190],[590,70],'#c83535',3);
        svg.append(node('circle',{cx:470,cy:130,r:4,fill:'#c83535'}));
        svg.append(node('text',{x:330,y:210},'A'));svg.append(node('text',{x:598,y:70},'B'));
        svg.append(node('text',{x:405,y:125,'text-anchor':'middle'},['左面','前面','底面'][i]));
        svg.append(node('text',{x:535,y:125,'text-anchor':'middle'},['右面','后面','顶面'][j]));
        svg.append(node('text',{x:425,y:225},'展开图：经过共同棱中点'));
        const heading=document.createElement('div');heading.textContent=p.title;
        const note=document.createElement('div');note.textContent='示意图：红线为所选路线，虚线表示背面；展开图为两个正方形，不增加原题尺寸。';
        box.append(heading,svg,note);
      } catch(error) {
        const note=document.createElement('div');note.className='render-error';note.textContent='正方体路径图未生成：数据格式不正确。已保留原始内容。';
        const fallback=document.createElement('pre');fallback.textContent=source;box.append(note,fallback);
      }
      code.parentElement.replaceWith(box);
    });
  }

  window.answerRenderer = {
    ready: true,
    render(turns, zoom, focusLatestDiagram) {
      const currentRevision = ++revision;
      const oldTop = window.scrollY;
      const atBottom = document.documentElement.scrollHeight - window.innerHeight - oldTop < 75;
      document.documentElement.style.fontSize = `${17 * Math.min(2.5, Math.max(.6, zoom || 1))}px`;
      transcript.replaceChildren();
      turns.forEach(turn => {
        const section = document.createElement('section'); section.className = 'turn';
        const question = document.createElement('div'); question.className = 'question';
        question.textContent = `你：${turn.question || ''}`;
        const answer = document.createElement('div'); answer.className = 'answer';
        renderMarkdown(turn.answer || '', answer);
        section.append(question, answer);
        (turn.diagramPNGs || []).forEach(png => {
          if (!/^[A-Za-z0-9+/=\r\n]+$/.test(png)) return;
          const image = document.createElement('img'); image.className = 'checked-diagram';
          image.alt = '解题图解'; image.src = 'data:image/png;base64,' + png; section.append(image);
        });
        if (turn.note) { const note = document.createElement('div'); note.className = 'note'; note.textContent = turn.note; section.append(note); }
        transcript.append(section);
        enhanceMermaid(answer, currentRevision);
        enhanceMathGrids(answer, currentRevision);
        enhanceGridRoutes(answer, currentRevision);
        enhanceCenterCuts(answer, currentRevision);
        enhanceRectangleDissections(answer, currentRevision);
        enhanceTriangleDissections(answer, currentRevision);
        enhanceHexagonPartitions(answer, currentRevision);
        enhanceCubePaths(answer, currentRevision);
      });
      if (focusLatestDiagram) {
        const diagrams = transcript.querySelectorAll('.diagram, .checked-diagram');
        if (diagrams.length) diagrams[diagrams.length - 1].scrollIntoView({ block: 'nearest' });
      } else if (atBottom) window.scrollTo(0, document.documentElement.scrollHeight);
      else window.scrollTo(0, oldTop);
      // PDF export must wait for queued diagrams and local fonts before measuring.
      return mermaidQueue.then(() => document.fonts.ready).then(() => true);
    }
  };
})();
