"""Construct a reversible listening plan. The classifier returns scores, never prose."""
from collections import Counter
from pathlib import Path
import re
import regex

YEAR = r"(?:1[5-9]\d{2}|20\d{2})[a-z]?"
NAME = r"(?:\p{Lu}[\p{L}\p{M}’'`.-]*|(?:de|del|der|van|von|da|di|le|la|the|and|&|et|al\.?))"
AUTHOR = rf"\p{{Lu}}[\p{{L}}\p{{M}}’'`.-]*(?:(?:[\s,]+){NAME}){{0,12}}"
LOC = r"(?:\s*[:,]\s*(?:pp?\.\s*|[§¶]\s*|y(?=\d))?\d+(?:\s*[–-]\s*\d+)?)?"
DATES = rf"{YEAR}(?:\s*[,/]\s*{YEAR})*{LOC}"
ITEM = regex.compile(rf"(?:(?i:see(?: also)?|cf\.|e\.g\.,?)\s+)?{AUTHOR},?\s+{DATES}")
HEADING = re.compile(r"^(?:\d+(?:\.\d+)*[.\s]+)?(?:references(?: cited)?|bibliography|works cited|literature cited)\s*[:.]?$", re.I)
RESUME = re.compile(r"^(?:(?:[A-Z]|\d+(?:\.\d+)*)[.\s]+)?(?:appendi(?:x|ces)|supplement(?:ary)?(?:\s+(?:materials?|information))?|acknowledg[e]?ments?|author contributions?|funding|conflict[s]? of interest|data availability|supporting information|about the authors?)\b",re.I)
INTRO = re.compile(r"^(?:abstract\b|(?:1[.)]?\s+)?introduction\s*$)",re.I)
SERVICE = re.compile(r"\b(?:alerts?|subscri(?:be|ption|ptions)|reprints?|permissions?|terms of (?:use|service)|additional services|rights reserved|downloaded (?:from|by)|accessed (?:on|via)|copyright|all rights|sign (?:in|up)|click here|how to cite|link to this article|publisher.s note|privacy policy|article metrics|online version|read online|view online|register for|published online|digital object identifier|doi\b)",re.I)
CONTACT = re.compile(r"(?:\b(?:e-?mail|correspondence)\b|@\s*[\w.-]+\.[a-z]{2,})", re.I)
MATH = re.compile(r"[=≤≥≈≠∑∫√∞∂∇∏±×÷∈⊂∪∩∀∃]|[α-ωΑ-Ω]")
NOTE = re.compile(r"^>\s*(\d{1,2})\s*(?=[A-Z‘“(])")
LINK = re.compile(r"(?:(?:https?://|www\.)\S+|doi\s*:\s*10\.\d{4,9}/\S+)",re.I)
VENUE = re.compile(r"^(?:Proceedings of\b|(?:[A-Z][^\n]{0,70}\s)?Journal (?:of|for)\b|Transactions (?:of|on)\b)",re.I)

def key(s):
    return ''.join(c for c in s.casefold() if c.isalnum())

def span(start, stop, raw, reason, group="cleanup", replacement=""):
    # Cocoa uses UTF-16 units, while Python indexes Unicode code points.
    at=len(raw[:start].encode("utf-16-le"))//2
    length=len(raw[start:stop].encode("utf-16-le"))//2
    return dict(at=at, length=length, reason=reason, group=group, replacement=replacement)

def classify(candidates, model_dir):
    if not candidates:
        return {}
    if model_dir is None:
        # Without the optional classifier, preserve uncertain author text.
        # Unambiguous formatting/citation/service rules still apply below.
        return {i: (0.0, 1.0) for i, _ in candidates}
    import torch
    from tokenizers import Tokenizer
    from transformers import AutoModelForSequenceClassification
    torch.set_num_threads(4)
    tokenizer=Tokenizer.from_file(str(model_dir/"tokenizer.json"))
    tokenizer.enable_truncation(max_length=320)
    tokenizer.enable_padding(pad_id=0,pad_token="[PAD]")
    model=AutoModelForSequenceClassification.from_pretrained(model_dir,local_files_only=True)
    model.eval()
    # CPU inference also works on Macs where Metal is unavailable.
    labels=("This is a publisher's website navigation, subscription, access, permissions, contact or reprint notice.",
            "This is a promotional message.",
            "This is the author's discussion, a section of the research paper, or its title, authors or publication name.")
    result={}
    with torch.inference_mode():
        for offset in range(0,len(candidates),6):
            batch=candidates[offset:offset+6]
            encoded=tokenizer.encode_batch([(text,h) for _,text in batch for h in labels])
            ids=torch.tensor([e.ids for e in encoded])
            mask=torch.tensor([e.attention_mask for e in encoded])
            p=model(input_ids=ids,attention_mask=mask).logits.softmax(-1)[:,model.config.label2id["entailment"]].tolist()
            for n,(i,_) in enumerate(batch):
                service,promotion,content = p[3*n:3*n+3]
                result[i]=(max(service,promotion),content)
    return result

def reference_entry(s):
    if re.match(r"^\s*(?:\[\d+\]|\d{1,3}\.\s+[A-Z])",s):
        return True
    year = re.search(YEAR+r"\b",s[:250])
    if year is None:
        return False
    # A year and a comma anywhere in a paragraph are not enough: prose such as
    # "In 2024, we repeated the experiment" can follow a reference list too.
    # Require an author-like prefix and leave uncertain paragraphs untouched.
    head = s[:year.start()].strip().rstrip(" ([,.:;")
    if (re.match(r"(?i)^(?:in|since|during|after|before|between|from|by|until)\b",head)
            or head.casefold() in {"the", "a", "an"}):
        return False
    return bool(regex.fullmatch(rf"(?:(?:de|del|der|van|von|da|di|le|la)\s+)*{AUTHOR}",head))

def citation_spans(s, surnames):
    result=[]
    for m in re.finditer(r"[\(\[]([^()\[\]\n]{2,450})[\)\]]",s):
        if (m[0][0],m[0][-1]) not in [('(',')'),('[',']')]: continue
        content=m[1].strip()
        parts=re.split(r"\s*;\s*",content)
        found=all(ITEM.fullmatch(part) and not MATH.search(part) for part in parts)
        if found and surnames and len(parts)==1 and not ("et al" in content or " and " in content or "&" in content):
            suspects=regex.findall(r"\b\p{Lu}[\p{L}’'\-]*",re.split(YEAR,content)[0])
            if not any(w.casefold() in surnames for w in suspects):
                found=False
        if found and (re.match(r"(?i)^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?|model|experiment|trial|figure|table|equation|version|phase|group|year|since|in|during|between|from|before|after)\b",content)
                      or any(re.search(r"\b(?:to|until|through)\b",part) for part in parts)):
            found=False
        if not found and re.fullmatch(DATES,content):
            # In "Latour (1994) argues", the surname is part of the author's sentence.
            preceding=regex.search(r"(\p{Lu}[\p{L}’'\-]+)(?:\s+et al\.?)?\s*$",s[:m.start()])
            found=bool(preceding and preceding[1].casefold() in surnames)
        if found:
            a=m.start()
            if a and s[a-1]==' ': a-=1
            # Avoid gluing adjacent words in tight PDF typesetting.
            gap=" " if a and m.end()<len(s) and s[a-1].isalnum() and s[m.end()].isalnum() else ""
            result.append(span(a,m.end(),s,"In-text citation","references",gap))
    # Unbracketed trailing citations require a surname found in this paper's bibliography.
    for m in regex.finditer(rf",\s*(\p{{Lu}}[\p{{L}}’'\-]+)\s+{YEAR}(?=[.;]|$)",s):
        if m[1].casefold() in surnames:
            result.append(span(m.start(),m.end(),s,"Trailing citation","references"))
    return result

def can_join(left,right):
    if not left or not right or MATH.search(left[-20:]+right[:15]): return False
    if not re.search(r"[\w,–—-]$",left): return False
    if not re.match(r"[(]?[a-zà-öø-ÿ]",right) and not (left.endswith(",") and right[:1].isupper()): return False
    return len(left.split())>=5 and not left.isupper()

def make_plan(text,title,model_dir,progress,roles=None):
    raw=[b.strip() for b in re.split(r"\n\s*\n",text) if b.strip()]
    roles=roles if roles and len(roles)==len(raw) else [""]*len(raw)
    units=[dict(raw=b,edits=[],order=i*10,kind=roles[i]) for i,b in enumerate(raw)]
    if not raw: return dict(units=[],classifierCount=0)
    def omit(i,why,group="cleanup"):
        units[i].update(reason=why,group=group)
    leading=raw[:40]
    heading=next((i for i,b in enumerate(leading) if INTRO.fullmatch(b.strip(" :."))),None)
    synopsis=next((i for i,b in enumerate(leading) if len(b.split())>18 and re.match(
        r"(?i)^(this (?:paper|article|study|research)|we (?:present|investigate|examine))\b",b)),None)
    if heading is not None or synopsis is not None:
        boundary=min(i for i in (heading,synopsis) if i is not None)
    else:
        boundary=next((i for i,b in enumerate(leading) if i and len(b.split())>=35 and
                       not (SERVICE.search(b) or CONTACT.search(b) or LINK.search(b))),len(leading))
    front=range(min(boundary,40))
    title_key=key(title)
    copies=[i for i in front if title_key and key(raw[i])==title_key]
    keep=set(copies[:1])
    byline=None
    if copies and copies[0]+1 in front:
        j=copies[0]+1
        if len(raw[j])<200 and not SERVICE.search(raw[j]) and not LINK.search(raw[j]) and not CONTACT.search(raw[j]):
            byline=j;keep.add(j)
    cover=any(re.search(r'(?i)^(additional services for|how to cite this article|link to this article)',raw[i]) for i in front)
    for i in copies[1:]:
        omit(i,"Repeated paper title")
    if byline is not None:
        for i in front:
            if i!=byline and key(raw[i])==key(raw[byline]):
                omit(i,"Repeated byline")
    # Recognise a cover masthead by its repetition in the issue line, not by guessing a journal.
    venue=None
    for i in front:
        if len(raw[i])<150 and (any(raw[j].casefold().startswith(raw[i].casefold()+" / volume") for j in front if j!=i) or VENUE.match(raw[i])):
            venue=i;keep.add(i);break
    if venue is not None and byline is not None and venue<byline and cover:
        units[venue]['order']=units[byline]['order']+1
    if venue is None and byline is not None:
        for i in range(min(len(raw),40)):
            if roles[i] in ("page-header","page-footer","venue") and VENUE.match(raw[i]) and len(raw[i])<320:
                venue=i;keep.add(i)
                units[i]["order"]=units[byline]["order"]+1
                # Keep the venue as printed and skip a separable imprint tail.
                tail=re.search(r"\s*[,]?\s+pages?\s+\d+[–-]\d+.*$",raw[i],re.I)
                if tail: units[i]["edits"].append(span(tail.start(),tail.end(),raw[i],"Publication imprint"))
                break
    for i in front:
        if venue is not None and raw[i].casefold().startswith(raw[venue].casefold()+" / volume") and 'doi' in raw[i].lower():
            omit(i,"Repeated journal and publication details")
        if i>0 and re.match(r"(?i)^how to cite (?:this|the) (?:article|paper)",raw[i-1]) and (title_key and title_key in key(raw[i])):
            omit(i,"Publisher's suggested citation")
    # Page numbers vary even when the running title or byline is identical.
    margin_keys = {i:key(re.sub(r"^\d+\s+|\s+\d+$","",b))
                   for i,b in enumerate(raw) if roles[i] in ("page-header","page-footer")}
    frequency = Counter(margin_keys.values())
    for i, token in margin_keys.items():
        b=raw[i]
        if i in keep: continue
        repeated = bool(token and frequency[token]>1 and
                        (re.search(r"^\d+\s|\s\d+$",b) or i!=next(j for j in margin_keys if margin_keys[j]==token)))
        imprint = venue is not None and b.casefold().startswith(raw[venue].casefold()+" ") and re.search(r"\d+\s*[(]\d+[)]",b)
        if b.isdecimal() or repeated or imprint or LINK.fullmatch(b) or re.match(r"(?i)^downloaded from https?://",b):
            omit(i,"Running page furniture")
    for i in front:
        if re.fullmatch(r"(?i)how to cite (this|the) (paper|article)\s*:",raw[i]) and i+1<len(raw) and units[i+1].get("reason")=="Publisher's suggested citation":
            omit(i,"Publisher service notice")
    for i in range(len(raw)):
        if HEADING.fullmatch(raw[i]) and any(reference_entry(x) for x in raw[i+1:i+4]):
            # Stop before appendices and other sections. Unexpected prose ends the list.
            omit(i,"Reference list","references")
            j=i+1
            while j<len(raw):
                s=raw[j]
                if units[j].get('reason')=='Running page furniture':
                    j+=1
                    continue
                if RESUME.match(s) or roles[j] in ("section-header","title","formula"): break
                if not (reference_entry(s) or s.startswith(("http://","https://")) or
                        (j>i+1 and not re.search(r'[.!?]$',raw[j-1]) and re.match(r'^[a-z]',s))):
                    break
                omit(j,"Bibliography entry","references");j+=1
    surnames=set()
    for u in units:
        if u.get('reason')=='Bibliography entry':
            s=re.sub(r'^\[?\d+\]?[.)]?\s*','',u['raw'])
            authorhead=re.split(YEAR,s,maxsplit=1)[0][:180]
            # The PDF extractor can place two bibliography records in one paragraph.
            surnames.update(w.casefold() for w in regex.findall(
                r"(?:^|[.]\s+)(\p{Lu}[\p{L}’'\-]+),\s*\p{Lu}\.\s*(?=\d{4}\b)",s))
            surnames.update(w.casefold() for w in regex.findall(r"\b\p{Lu}[\p{L}’'\-]{1,}\b",authorhead))
    # Expose unambiguous service notices and ask the classifier about less formulaic candidates.
    candidates=[]
    seen=Counter(key(b) for b in raw if b)
    for i,s in enumerate(raw):
        if units[i].get('reason') or i in keep or roles[i] in ('formula','title','section-header','table') or MATH.search(s): continue
        if roles[i] in ('page-header','page-footer') and (s.isdecimal() or (seen[key(s)]>1 and raw.index(s)<i)):
            omit(i,"Running page furniture");continue
        if i in front and LINK.fullmatch(s):
            omit(i,"Publisher link");continue
        if i in front and CONTACT.search(s) and '@' in s and not SERVICE.search(s) and len(s)<350 and not re.search(r'[.!?]\s+[A-Z][a-z]+\s',s):
            omit(i,"Author contact details");continue
        if len(s)<500 and (i in front or roles[i] in ('page-header','page-footer') or re.match(r'(?i)^(click here|subscriptions?\s*:|reprints?\s*:|downloaded from)',s)):
            if (i in front and 3<=len(s.split())<=55) or SERVICE.search(s) or re.search(r'(?i)^(vis(it|iting)|register|access|view|sign|receive|order|request|learn more|for more|for details|log in|read more)\b',s):
                candidates.append((i,s))
    if candidates and model_dir is not None:
        progress("Checking publisher notices with DeBERTa…")
    scores=classify(candidates,model_dir)
    for i,s in candidates:
        notice,body=scores[i]
        explicit=bool(re.fullmatch(r"(?is)(?:(?:email alerts?|subscriptions?|commercial reprints?|terms of use|request permissions?)\s*:\s*click here\s*[.;]?\s*)+",s)
                      or re.fullmatch(r"(?is)(?:additional services for [^.!?]{1,120}|how to cite this article):?",s)
                      or re.fullmatch(r"(?i)link to this article:\s*https?://\S+",s))
        evidence=SERVICE.search(s) or re.match(r"(?i)^(?:register|access|view|sign|receive|order|request|for more|for details|log in|read more|visit)\b",s)
        substantive=re.search(r"(?i)\b(?:this (?:paper|study|article) (?:shows?|argues?|examines?|explores?|finds?|investigates?)|we (?:found|show|argue|propose)|our (?:results|findings|experiments))\b",s)
        if not substantive and (explicit or (evidence and notice>=0.83 and notice>body+0.25)):
            omit(i,"Publisher service notice" if explicit else "Publisher notice · DeBERTa")
    note_numbers={m[1] for u in units if (m:=NOTE.match(u['raw']))}
    for i,u in enumerate(units):
        s=u['raw']
        if u.get('reason') or roles[i] in ('formula','table'): continue
        u['edits'].extend(citation_spans(s,surnames))
        # Remove only list-prefix glyphs, never the same glyph inside an expression.
        m=re.match(r'^(?:[•●▪\uf0b7]\s+)(?=[A-Za-z])',s)
        if m: u['edits'].append(span(0,m.end(),s,"List marker"))
        m=NOTE.match(s)
        if m: u['edits'].append(span(0,m.end(),s,"Footnote marker"))
        # A decimal/version suffix (3.1, 2.12) is author text, even when a
        # footnote with that same number exists elsewhere in the paper.
        for m in re.finditer(r'(?<!\d[.!?])(?<=[.!?])([1-9]\d?)(?=\s|$)',s):
            if m[1] in note_numbers: u['edits'].append(span(m.start(),m.end(),s,"Footnote marker"))
        for m in re.finditer(r'\u00ad|\u200b|\ufeff',s):
            u['edits'].append(span(m.start(),m.end(),s,"Invisible formatting character"))
    # Delay intervening footnotes until both halves of a broken sentence have been read.
    for i in range(1,len(raw)):
        j=i-1
        if NOTE.match(raw[i]): continue
        while j>=0 and (NOTE.match(raw[j]) or units[j].get('reason')=="Running page furniture" or
                         (j==venue and units[j]['order']!=j*10)): j-=1
        if j<0 or units[i].get('reason') or units[j].get('reason'): continue
        if roles[i] in ("section-header","title","formula","table") or roles[j] in ("section-header","title","formula","table"): continue
        if can_join(raw[j],raw[i]):
            units[i]['joinFrom']=j
            if j<i-1:
                units[i]['order']=j*10+1
    # A scholarly cover can omit the heading on the actual abstract. Add an optional
    # spoken label only when both the synopsis and subsequent numbered introduction are present.
    if boundary+1<len(raw) and re.match(r"(?i)^(this (paper|article|study)|we (present|investigate))\b",raw[boundary]) and re.fullmatch(r"(?i)(?:1[.)]?\s+)?introduction",raw[boundary+1]):
        units[boundary]['label']="Abstract"
    return dict(units=units,classifierCount=len(candidates) if model_dir is not None else 0)
