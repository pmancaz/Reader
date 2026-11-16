/* Reader extraction adapter. Runs only in an empty, network-blocked WKWebView.
 * Source markup remains in an inert DOMParser document. Never load source pages. */
function extractReaderArticle(sourceHTML, sourceURL) {
  const doc = new DOMParser().parseFromString(sourceHTML, 'text/html');
  // Preserve metadata for Readability, but remove executable/embedded content.
  doc.querySelectorAll('script,style,link,iframe,frame,object,embed,form,input,button,svg,math,video,audio,source,canvas,meta[http-equiv]').forEach(n => n.remove());
  doc.querySelectorAll('base').forEach(n => n.remove());
  const base = doc.createElement('base'); base.href = sourceURL; doc.head.prepend(base);
  for (const img of doc.querySelectorAll('img')) {
    const src = img.getAttribute('data-src') || img.getAttribute('data-original') || img.getAttribute('data-lazy-src') || img.getAttribute('src');
    if (src) { try { img.setAttribute('src', new URL(src, sourceURL).href); } catch (_) { img.removeAttribute('src'); } }
    img.removeAttribute('srcset');
    if ((img.width && img.width < 16) || (img.height && img.height < 16)) img.remove();
  }
  const article = new Readability(doc, { charThreshold: 80, keepClasses: false }).parse();
  if (!article || !article.textContent || article.textContent.trim().length < 80) return null;
  const safe = DOMPurify.sanitize(article.content, {
    ALLOWED_TAGS: ['p','div','section','article','h1','h2','h3','h4','h5','h6','ul','ol','li','blockquote','pre','code','em','strong','b','i','u','s','br','hr','a','img','figure','figcaption','table','thead','tbody','tfoot','tr','td','th','caption','dl','dt','dd','sub','sup','small','span'],
    ALLOWED_ATTR: ['href','src','alt','title','colspan','rowspan','start'],
    ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false, SANITIZE_NAMED_PROPS: true
  });
  const content = new DOMParser().parseFromString(safe, 'text/html');
  for (const link of content.querySelectorAll('a')) {
    try {
      const address = new URL(link.getAttribute('href') || '', sourceURL);
      if (!['https:', 'http:', 'mailto:'].includes(address.protocol)) link.removeAttribute('href');
      else { link.setAttribute('href', address.href); link.setAttribute('rel', 'noreferrer noopener'); }
    } catch (_) { link.removeAttribute('href'); }
  }
  const images = [];
  for (const img of content.querySelectorAll('img')) {
    try {
      const address = new URL(img.getAttribute('src') || '', sourceURL);
      if (!['http:', 'https:'].includes(address.protocol) || images.length >= 60) { img.remove(); continue; }
      const index = images.length; images.push({ url: address.href, alt: img.alt || '' });
      img.setAttribute('src', 'reader-image-' + index);
    } catch (_) { img.remove(); }
  }
  // textContent alone joins adjacent minified <p> elements. Preserve semantic
  // block boundaries for search, exports and the separate listening pipeline.
  // The actual saved DOM remains unchanged, so quote anchors retain their offsets.
  const textCopy = content.body.cloneNode(true);
  textCopy.querySelectorAll('br').forEach(n => n.replaceWith(textCopy.ownerDocument.createTextNode('\n')));
  textCopy.querySelectorAll('p,div,section,article,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure,tr,dt,dd').forEach(n => n.appendChild(textCopy.ownerDocument.createTextNode('\n\n')));
  const readableText = textCopy.textContent.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return { title: article.title || doc.title || 'Untitled article', author: article.byline || null,
           html: content.body.innerHTML, text: readableText || article.textContent, images };
}
