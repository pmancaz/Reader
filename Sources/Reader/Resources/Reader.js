(() => {
  const root = document.getElementById('reader-content') || document.querySelector('article') || document.body;
  function nodes() { const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {acceptNode:n => n.parentElement.closest('script,style') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT}); const out=[]; while(w.nextNode())out.push(w.currentNode); return out; }
  function plain() { return nodes().map(n=>n.textContent).join(''); }
  function post(type, value) { window.webkit?.messageHandlers?.reader?.postMessage({type,...value}); }
  function clear() { root.querySelectorAll('mark[data-reader-id]').forEach(m=>m.replaceWith(...m.childNodes)); root.normalize(); }
  function locate(a, text) {
    if(!a || !a.exact)return -1;
    const matches=[]; let i=text.indexOf(a.exact);
    while(i>=0){ let score=0; if(a.prefix && text.slice(Math.max(0,i-a.prefix.length),i)===a.prefix)score+=4; if(a.suffix && text.slice(i+a.exact.length,i+a.exact.length+a.suffix.length)===a.suffix)score+=4; if(i===a.start)score++; matches.push({i,score,d:Math.abs(i-(a.start||0))}); i=text.indexOf(a.exact,i+1); }
    matches.sort((a,b)=>b.score-a.score||a.d-b.d); return matches[0]?.i ?? -1;
  }
  window.ReaderAPI={
    selection(){const s=getSelection(); if(!s || s.isCollapsed || !s.rangeCount)return null;const r=s.getRangeAt(0); if(!root.contains(r.commonAncestorContainer))return null;
      const pre=document.createRange(); pre.selectNodeContents(root); pre.setEnd(r.startContainer,r.startOffset); const start=pre.toString().length, exact=r.toString(), text=plain();
      return {exact,start,end:start+exact.length,prefix:text.slice(Math.max(0,start-64),start),suffix:text.slice(start+exact.length,start+exact.length+64)};},
    render(annotations){clear(); const text=plain(); const anchors=annotations.filter(a=>a.articleAnchor).map(a=>({...a,offset:locate(a.articleAnchor,text)})).filter(a=>a.offset>=0); let offset=0;
      const spans=nodes().map(n=>{const s={n,start:offset,end:offset+n.length};offset=s.end;return s;});
      // Work backwards through original text nodes; overlapping passages share a visible mark.
      for(const part of spans.reverse()){
        const cuts=new Set([0,part.n.length]); const hits=anchors.filter(a=>a.offset<part.end && a.offset+a.articleAnchor.exact.length>part.start);
        for(const a of hits){cuts.add(Math.max(0,a.offset-part.start)); cuts.add(Math.min(part.n.length,a.offset+a.articleAnchor.exact.length-part.start));}
        const sorted=[...cuts].sort((a,b)=>a-b); const textValue=part.n.textContent; const frag=document.createDocumentFragment();
        for(let i=0;i<sorted.length-1;i++){const lo=sorted[i],hi=sorted[i+1]; const active=hits.filter(a=>a.offset<=part.start+lo&&a.offset+a.articleAnchor.exact.length>=part.start+hi);
          const t=document.createTextNode(textValue.slice(lo,hi)); if(active.length){const m=document.createElement('mark'); m.dataset.readerId=active[0].id; m.dataset.readerIds=active.map(a=>a.id).join(' '); m.appendChild(t); frag.appendChild(m);}else frag.appendChild(t);}
        part.n.replaceWith(frag);
      }
      return anchors.length;
    },
    jump(id){const m=[...root.querySelectorAll('mark[data-reader-ids]')].find(m=>m.dataset.readerIds.split(' ').includes(id));if(!m)return false;m.scrollIntoView({block:'center',behavior:'smooth'});return true;},
    position(){return Math.max(0,Math.min(1,scrollY/Math.max(1,document.documentElement.scrollHeight-innerHeight)));},
    restore(f){scrollTo(0,f*Math.max(0,document.documentElement.scrollHeight-innerHeight));},
    appearance(size,spacing,width,dark){document.documentElement.style.setProperty('--reader-size',size+'px');document.documentElement.style.setProperty('--reader-line',spacing);document.documentElement.style.setProperty('--reader-width',width+'px');document.documentElement.dataset.theme=dark?'dark':'light';}
  };
  const style=document.createElement('style'); style.textContent=`
  :root{color-scheme:light dark;--reader-size:19px;--reader-line:1.65;--reader-width:720px;--bg:#faf9f6;--fg:#292927;--muted:#6a6964;--link:#2c618a;--mark:#f3df8f}
  :root[data-theme=dark]{--bg:#242523;--fg:#e5e4df;--muted:#aaa9a1;--link:#9dc6e6;--mark:#645428}
  html,body{margin:0!important;padding:0!important;background:var(--bg)!important;color:var(--fg)!important;overflow-wrap:anywhere}
  body{width:100%;max-width:none!important;min-width:0;font-family:Georgia,serif!important;font-size:var(--reader-size)!important;line-height:var(--reader-line)!important;padding:48px max(28px,calc((100vw - var(--reader-width))/2)) 96px!important;box-sizing:border-box}
  article,#reader-content{max-width:var(--reader-width);margin:auto} h1,h2,h3,h4{line-height:1.25;letter-spacing:-.02em;margin:1.6em 0 .6em}h1{font-size:1.8em;margin-top:0}p,ul,ol,figure,pre{margin:1em 0}img{max-width:100%;height:auto;display:block;margin:1.5em auto}a{color:var(--link)}a:focus-visible{outline:3px solid var(--link);outline-offset:3px}blockquote{border-left:3px solid var(--muted);margin:1.5em 0;padding-left:1em;color:var(--muted)}pre{white-space:pre-wrap;background:#8881;padding:1em}table{display:block;overflow:auto;border-collapse:collapse}td,th{padding:.5em;border:1px solid #8885}mark[data-reader-id]{background:var(--mark);color:inherit;border-radius:2px}::selection{background:#68a5d955}figcaption{font-size:.85em;color:var(--muted)}
  `; document.head.appendChild(style);
  document.addEventListener('selectionchange',()=>post('selection',{selected:!!getSelection()?.toString()}));
  window.addEventListener('scroll',()=>post('progress',{fraction:window.ReaderAPI.position()}),{passive:true});
  post('ready',{});
})();
