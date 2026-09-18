#!/usr/bin/env python3
"""Create offline interactive HTML plots for the bacterial downstream suite."""
from __future__ import annotations

import base64
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Iterable
from collections import Counter, defaultdict

import networkx as nx
import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
from plotly.subplots import make_subplots


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def read_table(path: str) -> pd.DataFrame:
    suffix = Path(path).suffix.lower()
    if suffix in {".csv"}:
        return pd.read_csv(path)
    return pd.read_csv(path, sep="\t")


def normalize_id_column(df: pd.DataFrame, preferred: str = "gene_id") -> pd.DataFrame:
    if preferred not in df.columns:
        df = df.rename(columns={df.columns[0]: preferred})
    df[preferred] = df[preferred].astype(str)
    return df


def _figure_has_visible_colorbar(fig: go.Figure) -> bool:
    """Return True when Plotly will render a numeric colour scale.

    Plotly places colour bars outside the Cartesian paper by default.  The
    embedded report clips everything to its iframe, so figures with the normal
    small right margin could render the plot correctly while cutting off the
    complete bar.  Detect both shared colour axes and trace-owned colour bars
    before the HTML is written so enough canvas is always reserved.
    """
    layout = fig.layout.to_plotly_json()
    for key, value in layout.items():
        if re.fullmatch(r"coloraxis\d*", str(key)) and isinstance(value, dict):
            if value.get("showscale", True) is not False:
                return True

    colour_trace_types = {
        "heatmap", "contour", "histogram2d", "histogram2dcontour",
        "surface", "mesh3d", "cone", "streamtube", "isosurface", "volume",
        "choropleth", "choroplethmap", "choroplethmapbox",
    }
    for trace in fig.data:
        payload = trace.to_plotly_json()
        marker = payload.get("marker") if isinstance(payload.get("marker"), dict) else {}
        if marker.get("showscale") is True:
            return True
        if payload.get("showscale") is True:
            return True
        if str(payload.get("type", "")).lower() in colour_trace_types and payload.get("showscale", True) is not False:
            return True
    return False


def write_plot(fig: go.Figure, output_path: Path, title: str | None = None) -> None:
    """Write a standalone Plotly HTML that also behaves cleanly when embedded.

    The main Visualization Studio owns the toolbar while a specialized plot is
    embedded.  The same HTML keeps its lightweight export controls when opened
    directly from the result folder.
    """
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if title:
        fig.update_layout(title=title)
    existing_margin = fig.layout.margin.to_plotly_json() if fig.layout.margin is not None else {}
    merged_margin = {"l": 70, "r": 35, "t": 52, "b": 58, **existing_margin}
    if _figure_has_visible_colorbar(fig):
        # The colour bar, tick labels, and title all have to fit inside the
        # iframe.  Once the user drags the bar away from the right edge, the
        # browser-side handler releases this reserve and the graph widens.
        merged_margin["r"] = max(170, int(merged_margin.get("r", 35) or 35))
    fig.update_layout(
        template="plotly_white",
        paper_bgcolor="#ffffff",
        plot_bgcolor="#ffffff",
        font={"family": "Segoe UI, Arial, sans-serif", "size": 13},
        margin=merged_margin,
        hoverlabel={
            "namelength": -1,
            "bgcolor": "#ffffff",
            "bordercolor": "#789083",
            "font": {"color": "#173426", "family": "Segoe UI, Arial, sans-serif", "size": 13},
            "align": "left",
        },
        dragmode="pan",
    )
    # Keep the scientific axes visually explicit in every Cartesian result.
    # Schematic/network figures intentionally hide their axes and are left alone.
    for axis in fig.select_xaxes():
        if axis.visible is not False:
            current_standoff = axis.title.standoff if axis.title is not None else None
            axis.update(
                title_standoff=current_standoff if current_standoff is not None else 14,
                automargin=True,
                showgrid=False,
                showline=True,
                linecolor="#000000",
                linewidth=1.15,
                ticks="outside",
                tickcolor="#000000",
                mirror=False,
            )
    for axis in fig.select_yaxes():
        if axis.visible is not False:
            current_standoff = axis.title.standoff if axis.title is not None else None
            axis.update(
                title_standoff=current_standoff if current_standoff is not None else 12,
                automargin=True,
                showgrid=False,
                showline=True,
                linecolor="#000000",
                linewidth=1.15,
                ticks="outside",
                tickcolor="#000000",
                mirror=False,
            )
    plot_config = {
        "responsive": True,
        "displaylogo": False,
        "scrollZoom": True,
        "modeBarButtonsToRemove": ["toImage"],
        # Use Plotly's own edit layer for colour bars.  This works across SVG,
        # WebGL, Cartesian, and polar traces and avoids competing pointer
        # handlers that could collapse the plotting domains.
        "editable": True,
        "edits": {
            "annotationPosition": False,
            "annotationTail": False,
            "annotationText": False,
            "axisTitleText": False,
            "colorbarPosition": True,
            "colorbarTitleText": False,
            "legendPosition": False,
            "legendText": False,
            "shapePosition": False,
            "titleText": False,
        },
    }
    fig.write_html(
        str(output_path),
        include_plotlyjs="directory",
        full_html=True,
        config=plot_config,
    )
    try:
        text = output_path.read_text(encoding="utf-8", errors="replace")
        # In the combined report, every specialized plot must use the iframe's
        # actual viewport height.  A fixed standalone figure height used to be
        # clipped at the bottom, which hid the x-axis even though the axis was
        # present in the Plotly figure.  Keep the DAG responsive as well: its
        # former 1320-pixel minimum width pushed the colour bar outside the
        # visible iframe on ordinary laptop displays.
        embedded_min = ".bra-embedded .js-plotly-plot{width:100vw!important;height:100vh!important;min-height:0!important}"
        css = f"""<style>
html,body{{margin:0;padding:0;background:#fff}}
body{{overflow:auto}}
.plot-export-bar{{max-width:1100px;margin:10px auto 4px;display:flex;justify-content:flex-end;align-items:center;gap:7px;font:12px/1.25 \"Segoe UI\",Arial,sans-serif}}
.plot-export-bar select,.plot-export-bar button{{border:1px solid #cfd9d2;border-radius:8px;background:#fff;color:#1f2b24;padding:6px 8px;font:inherit}}.plot-export-bar button{{cursor:pointer}}.plot-export-note{{color:#557064;margin-right:auto}}
.js-plotly-plot .plotly .modebar{{left:8px!important;right:auto!important;top:8px!important}}
.js-plotly-plot g.colorbar{{cursor:grab}}
.js-plotly-plot.bra-colorbar-dragging g.colorbar{{cursor:grabbing}}
.js-plotly-plot .bra-cell-label-draggable{{cursor:move!important;touch-action:none}}
.js-plotly-plot .bra-selection-info-annotation text{{font-size:min(var(--bra-plot-font-size,12px),12px)!important}}
.bra-embedded .plot-export-bar,.bra-embedded .js-plotly-plot .plotly .modebar{{display:none!important}}
.bra-embedded{{overflow:hidden;height:100vh}}
{embedded_min}
</style>"""
        toolbar = """<div class="plot-export-bar"><span class="plot-export-note">Maximum-quality export · SVG is vector and can be enlarged without pixelation</span><select id="braExportFormat"><option value="png">PNG</option><option value="svg">SVG · vector</option><option value="pdf">PDF</option><option value="tiff">TIFF</option><option value="jpeg">JPEG</option><option value="webp">WebP</option></select><button type="button" id="braExportButton">Export</button></div>"""
        export_script = r"""<script>
(()=>{
const MAX_PIXELS=100000000,MAX_DIM=12000,graph=()=>document.querySelector('.plotly-graph-div');
const stem=__STEM__;
function safe(v){return String(v||'Bacterial RNA plot').replace(/[<>:"/\\|?*\x00-\x1F]+/g,'_').replace(/[. ]+$/g,'').slice(0,140)||'Bacterial RNA plot';}
function blobFromUri(uri,type){const comma=uri.indexOf(','),meta=uri.slice(5,comma),payload=uri.slice(comma+1);let bytes;if(/;base64/i.test(meta)){const raw=atob(payload);bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);}else bytes=new TextEncoder().encode(decodeURIComponent(payload));return new Blob([bytes],{type:type||meta.split(';')[0]||'application/octet-stream'});}
function save(blob,name){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);}
function byteJoin(parts){const total=parts.reduce((sum,part)=>sum+part.length,0),out=new Uint8Array(total);let offset=0;for(const part of parts){out.set(part,offset);offset+=part.length;}return out;}
function textBytes(value){return new TextEncoder().encode(String(value));}
async function pdfFromJpeg(uri,pixelWidth,pixelHeight,pageWidthMm=297,pageHeightMm=210){const jpeg=await awaitBlobBytes(blobFromUri(uri,'image/jpeg')),pageWidth=Math.max(72,Number(pageWidthMm)||297)*72/25.4,pageHeight=Math.max(72,Number(pageHeightMm)||210)*72/25.4,scale=Math.min(pageWidth/pixelWidth,pageHeight/pixelHeight),drawWidth=pixelWidth*scale,drawHeight=pixelHeight*scale,x=(pageWidth-drawWidth)/2,y=(pageHeight-drawHeight)/2,content=`q\n${drawWidth.toFixed(3)} 0 0 ${drawHeight.toFixed(3)} ${x.toFixed(3)} ${y.toFixed(3)} cm\n/Im0 Do\nQ\n`,objects=[textBytes('<< /Type /Catalog /Pages 2 0 R >>'),textBytes('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),textBytes(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth.toFixed(3)} ${pageHeight.toFixed(3)}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`),byteJoin([textBytes(`<< /Type /XObject /Subtype /Image /Width ${pixelWidth} /Height ${pixelHeight} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`),jpeg,textBytes('\nendstream')]),textBytes(`<< /Length ${textBytes(content).length} >>\nstream\n${content}endstream`)];const header=textBytes('%PDF-1.4\n'),parts=[header],offsets=[0];let cursor=header.length;objects.forEach((body,index)=>{offsets.push(cursor);const object=byteJoin([textBytes(`${index+1} 0 obj\n`),body,textBytes('\nendobj\n')]);parts.push(object);cursor+=object.length;});const xref=cursor,rows=offsets.slice(1).map(offset=>String(offset).padStart(10,'0')+' 00000 n \n').join(''),tail=textBytes(`xref\n0 ${objects.length+1}\n0000000000 65535 f \n${rows}trailer\n<< /Size ${objects.length+1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);parts.push(tail);return new Blob(parts,{type:'application/pdf'});}
async function awaitBlobBytes(blob){return new Uint8Array(await blob.arrayBuffer());}
function maxSize(ratio){ratio=Math.max(.05,Math.min(20,ratio||1));let w=Math.sqrt(MAX_PIXELS*ratio),h=w/ratio,f=Math.min(1,MAX_DIM/Math.max(w,h));return {width:Math.floor(w*f),height:Math.floor(h*f)};}
function plan(w,h){const ratio=w/h;let bw=Math.min(1800,w),bh=Math.round(bw/ratio);if(bh>1600){bh=Math.min(1600,h);bw=Math.round(bh*ratio);}const scale=Math.max(1,Math.min(w/bw,h/bh));return {bw,bh,scale};}
async function image(uri){return await new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=()=>reject(new Error('Could not decode export image.'));im.src=uri;});}
async function canvasBlob(uri,fmt){const im=await image(uri),c=document.createElement('canvas');c.width=im.naturalWidth;c.height=im.naturalHeight;const ctx=c.getContext('2d',{alpha:fmt!=='jpeg'});if(!ctx)throw new Error('Could not allocate export canvas. Use SVG.');if(fmt==='jpeg'){ctx.fillStyle='#fff';ctx.fillRect(0,0,c.width,c.height);}ctx.drawImage(im,0,0);return await new Promise((resolve,reject)=>c.toBlob(b=>b?resolve(b):reject(new Error(fmt+' export is not supported by this browser.')),fmt==='jpeg'?'image/jpeg':'image/webp',1));}
function tiffBlob(data,w,h){const bytes=w*h*3,n=13,ifd=8,ifdBytes=2+n*12+4;let cur=ifd+ifdBytes,bits=cur;cur+=6;if(cur%2)cur++;const xr=cur;cur+=8,yr=cur;cur+=8,pix=cur,buf=new ArrayBuffer(pix+bytes),v=new DataView(buf);v.setUint8(0,73);v.setUint8(1,73);v.setUint16(2,42,true);v.setUint32(4,ifd,true);v.setUint16(ifd,n,true);let p=ifd+2;const e=(tag,type,count,val)=>{v.setUint16(p,tag,true);v.setUint16(p+2,type,true);v.setUint32(p+4,count,true);if(type===3&&count===1){v.setUint16(p+8,val,true);v.setUint16(p+10,0,true);}else v.setUint32(p+8,val,true);p+=12;};e(256,4,1,w);e(257,4,1,h);e(258,3,3,bits);e(259,3,1,1);e(262,3,1,2);e(273,4,1,pix);e(277,3,1,3);e(278,4,1,h);e(279,4,1,bytes);e(282,5,1,xr);e(283,5,1,yr);e(284,3,1,1);e(296,3,1,2);v.setUint32(p,0,true);v.setUint16(bits,8,true);v.setUint16(bits+2,8,true);v.setUint16(bits+4,8,true);v.setUint32(xr,600,true);v.setUint32(xr+4,1,true);v.setUint32(yr,600,true);v.setUint32(yr+4,1,true);const src=data.data,dst=new Uint8Array(buf,pix,bytes);for(let i=0,j=0;i<src.length;i+=4){dst[j++]=src[i];dst[j++]=src[i+1];dst[j++]=src[i+2];}return new Blob([buf],{type:'image/tiff'});}
async function tiff(uri){const im=await image(uri),c=document.createElement('canvas');c.width=im.naturalWidth;c.height=im.naturalHeight;const ctx=c.getContext('2d',{alpha:false,willReadFrequently:true});if(!ctx)throw new Error('Could not allocate TIFF canvas. Use SVG.');ctx.fillStyle='#fff';ctx.fillRect(0,0,c.width,c.height);ctx.drawImage(im,0,0);return tiffBlob(ctx.getImageData(0,0,c.width,c.height),c.width,c.height);}
async function run(options={}){const g=graph(),btn=document.getElementById('braExportButton'),fmt=document.getElementById('braExportFormat')?.value||'png';if(!g)return;const old=btn?.textContent||'Export';if(btn){btn.disabled=true;btn.textContent='Exporting…';}try{if(fmt==='svg'){const rect=g.getBoundingClientRect(),ratio=Math.max(.05,rect.width/Math.max(1,rect.height)),uri=await Plotly.toImage(g,{format:'svg',width:2400,height:Math.round(2400/ratio),scale:1});save(blobFromUri(uri,'image/svg+xml'),safe(stem)+'.svg');return;}const rect=g.getBoundingClientRect(),size=maxSize(rect.width/Math.max(1,rect.height)),rp=plan(size.width,size.height);if(fmt==='pdf'){const uri=await Plotly.toImage(g,{format:'jpeg',width:rp.bw,height:rp.bh,scale:rp.scale});save(await pdfFromJpeg(uri,Math.round(rp.bw*rp.scale),Math.round(rp.bh*rp.scale),Number(options?.pageWidthMm)||297,Number(options?.pageHeightMm)||210),safe(stem)+'.pdf');return;}const uri=await Plotly.toImage(g,{format:'png',width:rp.bw,height:rp.bh,scale:rp.scale});let blob,ext=fmt;if(fmt==='png')blob=blobFromUri(uri,'image/png');else if(fmt==='jpeg'||fmt==='webp')blob=await canvasBlob(uri,fmt);else if(fmt==='tiff'){blob=await tiff(uri);ext='tif';}else throw new Error('Unsupported format');save(blob,safe(stem)+'.'+(fmt==='jpeg'?'jpg':ext));}catch(err){alert('Plot export failed: '+err.message);}finally{if(btn){btn.disabled=false;btn.textContent=old;}}}
window.BRA_exportCurrentPlot=run;
document.getElementById('braExportButton')?.addEventListener('click',run);
})();
</script>""".replace('__STEM__', json.dumps(output_path.stem))
        selection_script = r"""<script>
// BRA_SELECTION_RUNTIME_VERSION: 32
(()=>{
const graph=()=>document.querySelector('.plotly-graph-div');
if(window.parent&&window.parent!==window)document.body.classList.add('bra-embedded');
function selectionArray(custom){if(Array.isArray(custom))return custom;if(ArrayBuffer.isView(custom))return Array.from(custom);if(custom&&typeof custom==='object'&&custom[0]!==undefined){try{return Array.from(custom);}catch(_err){}}return null;}
function parseSelection(custom){
  const values=selectionArray(custom);if(!values||values[0]!=='BRA_SELECTION')return null;
  const genes=String(values[3]||'').split(/[\/;,|]+/).map(x=>x.trim()).filter(Boolean);
  return {type:'bra-specialized-selection',term_id:String(values[1]||''),label:String(values[2]||values[1]||'Selected item'),genes:[...new Set(genes)],context:values.slice(4)};
}
function send(payload){if(window.parent&&window.parent!==window)window.parent.postMessage(payload,'*');if(window.opener&&!window.opener.closed){window.opener.postMessage(payload,'*');try{window.opener.focus();}catch(_err){}}}
function pointGenes(custom){const values=selectionArray(custom);if(!values||values[0]!=='BRA_SELECTION')return [];return String(values[3]||'').split(/[\/;,|]+/).map(x=>x.trim()).filter(Boolean);}
function normalizedGenes(values){return [...new Set((Array.isArray(values)?values:[values]).map(value=>String(value||'').trim()).filter(Boolean))];}
function safeHtml(value){return String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));}
function wrappedHtml(value,width=38,maxLines=5){
  const text=String(value??'').replace(/\s+/g,' ').trim();if(!text)return '';
  const words=[];for(const token of text.split(' ')){if(token.length<=width)words.push(token);else for(let offset=0;offset<token.length;offset+=width)words.push(token.slice(offset,offset+width));}
  const lines=[];let line='';for(const word of words){const next=line?line+' '+word:word;if(!line||next.length<=width)line=next;else{lines.push(line);line=word;if(lines.length>=maxLines-1)break;}}if(line&&lines.length<maxLines)lines.push(line);
  const used=lines.join(' ');if(used.length<text.length&&lines.length)lines[lines.length-1]=lines[lines.length-1].replace(/[.…]*$/,'')+'…';return lines.map(safeHtml).join('<br>');
}
function compactTickHtml(value){const number=Number(value);if(!Number.isFinite(number))return wrappedHtml(value,24,3);const absolute=Math.abs(number);if(absolute!==0&&(absolute<.001||absolute>=10000)){const parts=number.toExponential(2).split('e'),exponent=Number(parts[1]);return `${Number(parts[0])}×10<sup>${exponent}</sup>`;}return safeHtml(Number(number.toPrecision(6)).toString());}
function quantile(sorted,p){if(!sorted.length)return NaN;const index=(sorted.length-1)*p,lo=Math.floor(index),hi=Math.ceil(index);return lo===hi?sorted[lo]:sorted[lo]+(sorted[hi]-sorted[lo])*(index-lo);}
function selectionInfoEnabled(){return window.__braShowSelectionInfo!==false;}
function cancelSelectionHover(g){clearTimeout(g?.__braHoverTimer);if(g){g.__braHoverTimer=null;g.__braHoverRevision=Number(g.__braHoverRevision||0)+1;}try{Plotly.Fx.unhover(g);}catch(_err){}}
function scheduleSelectionHover(g,match,delay=60){cancelSelectionHover(g);const revision=g.__braHoverRevision;g.__braHoverTimer=setTimeout(()=>{if(revision!==g.__braHoverRevision||!g.__braHasSelection||!selectionInfoEnabled())return;try{Plotly.Fx.hover(g,[match]);}catch(_err){}},delay);}
function clearTransientInfo(g,restoreMargin=true){
  cancelSelectionHover(g);
  try{Plotly.Fx.unhover(g);}catch(_err){}
  const annotations=(Array.isArray(g?.layout?.annotations)?g.layout.annotations:[]).filter(item=>!String(item?.name||'').startsWith('BRA_SELECTION_INFO'));
  if(g?.layout?.meta?.bra_kind==='single_gene_expression'&&!g.__braHasSelection&&g.__braSingleGeneEmptyAnnotation&&!annotations.some(item=>String(item?.name||'')==='BRA_SINGLE_GENE_EMPTY'))annotations.push({...g.__braSingleGeneEmptyAnnotation});
  if(g)g.__braSingleGeneInfoKey='';
  const update={annotations};if(restoreMargin&&g?.layout?.meta?.bra_kind==='single_gene_expression'){if(Number.isFinite(Number(g.__braSingleGeneBaseLeft)))update['margin.l']=Number(g.__braSingleGeneBaseLeft);if(Number.isFinite(Number(g.__braSingleGeneBaseRight)))update['margin.r']=Number(g.__braSingleGeneBaseRight);}
  try{return Promise.resolve(Plotly.relayout(g,update)).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function statisticText(value){const number=Number(value);if(!Number.isFinite(number))return 'NA';const absolute=Math.abs(number);return (absolute!==0&&(absolute>=100000||absolute<.0001))?number.toExponential(4):Number(number.toPrecision(7)).toString();}
function conditionStatistics(values){const sorted=(values||[]).map(Number).filter(Number.isFinite).sort((a,b)=>a-b);if(!sorted.length)return null;const q1=quantile(sorted,.25),median=quantile(sorted,.5),q3=quantile(sorted,.75),iqr=q3-q1,lowerLimit=q1-1.5*iqr,upperLimit=q3+1.5*iqr,lower=sorted.find(value=>value>=lowerLimit),upper=[...sorted].reverse().find(value=>value<=upperLimit);return [['max',sorted[sorted.length-1]],['upper fence',upper??sorted[sorted.length-1]],['q3',q3],['median',median],['q1',q1],['lower fence',lower??sorted[0]],['min',sorted[0]]];}
function showSingleGeneBoxInfo(g){
  if(g?.layout?.meta?.bra_kind!=='single_gene_expression'||!g.__braHasSelection||!selectionInfoEnabled())return;
  const meta=g.layout?.meta||{},gene=String(g.__braSelectedGenes?.[0]||''),conditions=Array.isArray(meta.bra_conditions)?meta.bra_conditions:[],values=meta.bra_expression_by_gene?.[gene];if(!Array.isArray(values)||!values.length)return;
  const groups=new Map();conditions.forEach((condition,index)=>{const key=String(condition||'Unassigned');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(values[index]);});
  const key=gene+'|'+Number(g.__braSelectionRevision||0)+'|'+[...groups.keys()].join('|');if(g.__braSingleGeneInfoKey===key)return;
  const annotations=(Array.isArray(g.layout?.annotations)?g.layout.annotations:[]).filter(item=>!String(item?.name||'').startsWith('BRA_SELECTION_INFO'));
  const entries=[...groups.entries()],labels={'max':'Max','upper fence':'Upper fence','q3':'Q3','median':'Median','q1':'Q1','lower fence':'Lower fence','min':'Min'};
  entries.forEach(([condition,groupValues],conditionIndex)=>{const stats=conditionStatistics(groupValues);if(!stats)return;const median=stats.find(([label])=>label==='median')?.[1]??stats[0][1],above=conditionIndex%2===0,text=[`<b>${wrappedHtml(condition,24,2)}</b>`,...stats.map(([label,value])=>`${labels[label]||safeHtml(label)}: ${statisticText(value)}`)].join('<br>');annotations.push({name:`BRA_SELECTION_INFO_BOX_${conditionIndex}`,x:condition,y:median,xref:'x',yref:'y',text,showarrow:true,arrowhead:0,arrowsize:.7,arrowwidth:1.2,arrowcolor:'#6a8f7d',ax:0,ay:above?-118:118,xanchor:'center',yanchor:above?'bottom':'top',align:'left',bgcolor:'rgba(255,255,255,.97)',bordercolor:'#789083',borderwidth:1.2,borderpad:6,font:{size:11,color:'#1e2a22'},captureevents:false});});
  const baseLeft=Number(g.__braSingleGeneBaseLeft)||65,baseRight=Number(g.__braSingleGeneBaseRight)||35;try{const work=Plotly.relayout(g,{annotations,'margin.l':baseLeft,'margin.r':baseRight});g.__braSingleGeneInfoKey=key;Promise.resolve(work).catch(()=>{if(g.__braSingleGeneInfoKey===key)g.__braSingleGeneInfoKey='';});}catch(_err){g.__braSingleGeneInfoKey='';}
}
function scheduleSingleGeneBoxInfo(g){
  clearTimeout(g.__braHoverTimer);
  const revision=Number(g.__braSelectionRevision||0);
  g.__braHoverTimer=setTimeout(()=>{if(revision===Number(g.__braSelectionRevision||0))showSingleGeneBoxInfo(g);},80);
}
async function resetSingleGeneExpression(g){
  if(g?.layout?.meta?.bra_kind!=='single_gene_expression')return;
  g.__braBoxCondition='';g.__braSingleGeneInfoKey='';
  await Plotly.restyle(g,{x:[[]],y:[[]],customdata:[[]],name:'Selected gene'},[0]);
  await Plotly.relayout(g,{'title.text':'','xaxis.autorange':true,'yaxis.autorange':true});
}
function singleGeneExpression(g,gene){
  const meta=g?.layout?.meta||{},matrix=meta.bra_expression_by_gene;
  if(meta.bra_kind!=='single_gene_expression'||!matrix||!Object.prototype.hasOwnProperty.call(matrix,gene))return false;
  const originalAnnotations=Array.isArray(g.layout?.annotations)?g.layout.annotations:[],emptyAnnotation=originalAnnotations.find(item=>String(item?.name||'')==='BRA_SINGLE_GENE_EMPTY');if(emptyAnnotation&&!g.__braSingleGeneEmptyAnnotation)g.__braSingleGeneEmptyAnnotation={...emptyAnnotation};
  const samples=Array.isArray(meta.bra_samples)?meta.bra_samples:[],conditions=Array.isArray(meta.bra_conditions)?meta.bra_conditions:[],values=matrix[gene],custom=samples.map((sample,index)=>['BRA_SELECTION',gene,gene,gene,sample,conditions[index]||'']),annotations=originalAnnotations.filter(item=>!String(item?.name||'').startsWith('BRA_SELECTION_INFO')&&String(item?.name||'')!=='BRA_SINGLE_GENE_EMPTY');
  if(!Number.isFinite(Number(g.__braSingleGeneBaseLeft)))g.__braSingleGeneBaseLeft=Number(g.layout?.margin?.l??g._fullLayout?.margin?.l??65);
  if(!Number.isFinite(Number(g.__braSingleGeneBaseRight)))g.__braSingleGeneBaseRight=Number(g.layout?.margin?.r??g._fullLayout?.margin?.r??40);
  const left=Number(g.__braSingleGeneBaseLeft)||65,right=Number(g.__braSingleGeneBaseRight)||35;g.__braSingleGeneInfoKey='';
  g.__braHasSelection=true;g.__braSelectedGenes=[gene];
  try{return Promise.resolve(Plotly.restyle(g,{x:[conditions],y:[values],name:gene,customdata:[custom],width:0.55,hoveron:'boxes',hovertemplate:null,hoverinfo:'all',yhoverformat:'.6f'},[0])).then(()=>Plotly.relayout(g,{'title.text':'Single-gene expression · '+gene,annotations,'margin.l':left,'margin.r':right,'xaxis.type':'category','xaxis.autorange':true,'yaxis.autorange':true})).then(()=>fitEmbedded(g)).then(()=>scheduleSingleGeneBoxInfo(g));}catch(_err){return Promise.resolve();}
}
function selectedGeneHeatmap(g,genes){
  const meta=g?.layout?.meta||{},matrix=meta.bra_heatmap_by_gene;
  if(meta.bra_kind!=='top_variable_gene_heatmap'||!matrix)return false;
  const chosen=normalizedGenes(genes).filter(gene=>Object.prototype.hasOwnProperty.call(matrix,gene)).slice(0,250);if(!chosen.length)return false;
  rememberTopVariableHeatmap(g);
  const samples=Array.isArray(meta.bra_samples)?meta.bra_samples:[],z=chosen.map(gene=>matrix[gene]),custom=chosen.map(gene=>samples.map(sample=>['BRA_SELECTION',gene,gene,gene,sample]));
  const height=Math.max(440,Math.min(1500,13*chosen.length+180));
  const displayHeight=window.parent&&window.parent!==window?Math.max(300,window.innerHeight-2):height;
  g.__braTopVariableIsFocused=true;
  try{return Promise.resolve(Plotly.restyle(g,{z:[z],y:[chosen],customdata:[custom]},[0])).then(()=>Plotly.relayout(g,{'title.text':chosen.length===1?'Selected gene heatmap · '+chosen[0]:'Selected genes heatmap · '+chosen.length+' genes',height:displayHeight,'xaxis.visible':true,'xaxis.showticklabels':true,'xaxis.autorange':true,'yaxis.visible':true,'yaxis.autorange':true})).then(()=>safeResize(g)).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function cloneNested(value){if(Array.isArray(value))return value.map(cloneNested);if(ArrayBuffer.isView(value))return Array.from(value,cloneNested);return value;}
function rememberTopVariableHeatmap(g){
  if(g?.layout?.meta?.bra_kind!=='top_variable_gene_heatmap'||g.__braTopVariableDefault||!g.data?.[0])return;
  const trace=g.data[0],meta=g.layout.meta||{};
  g.__braTopVariableDefault={z:cloneNested(trace.z||[]),y:cloneNested(trace.y||[]),customdata:cloneNested(trace.customdata||[]),title:String(meta.bra_default_title||g.layout?.title?.text||'Top variable genes'),height:Number(meta.bra_default_height||g.layout?.height||720)};
}
function restoreTopVariableHeatmap(g){
  if(g?.layout?.meta?.bra_kind!=='top_variable_gene_heatmap')return false;
  rememberTopVariableHeatmap(g);const saved=g.__braTopVariableDefault;if(!saved)return false;
  const displayHeight=window.parent&&window.parent!==window?Math.max(300,window.innerHeight-2):saved.height;
  g.__braTopVariableIsFocused=false;
  try{return Promise.resolve(Plotly.restyle(g,{z:[cloneNested(saved.z)],y:[cloneNested(saved.y)],customdata:[cloneNested(saved.customdata)]},[0])).then(()=>Plotly.relayout(g,{'title.text':saved.title,height:displayHeight,'xaxis.title.text':'Sample','xaxis.visible':true,'xaxis.showticklabels':true,'xaxis.autorange':true,'yaxis.title.text':'Gene','yaxis.visible':true,'yaxis.showticklabels':true,'yaxis.autorange':true})).then(()=>safeResize(g)).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function bindTopVariableBlankRestore(g){
  if(g?.layout?.meta?.bra_kind!=='top_variable_gene_heatmap'||g.__braTopVariableBlankBound)return;
  g.__braTopVariableBlankBound=true;let press=null;
  g.addEventListener('pointerdown',event=>{if(event.button!==0||event.target?.closest?.('.modebar')||event.target?.closest?.('g.colorbar'))return;press={time:Date.now(),x:event.clientX,y:event.clientY,moved:false};},true);
  g.addEventListener('pointermove',event=>{if(press&&Math.hypot(event.clientX-press.x,event.clientY-press.y)>5)press.moved=true;},true);
  g.addEventListener('pointerup',()=>{const current=press;press=null;if(!current||current.moved)return;setTimeout(()=>{if(!g.__braTopVariableIsFocused||Number(g.__braLastDataClickAt||0)>=current.time)return;if(restoreTopVariableHeatmap(g))send({type:'bra-specialized-clear-selection'});},100);},true);
  if(typeof g.on==='function')g.on('plotly_deselect',()=>{if(g.__braTopVariableIsFocused&&restoreTopVariableHeatmap(g))send({type:'bra-specialized-clear-selection'});});
}
function eventHitsPlotDatum(event){
  const target=event?.target;if(!target||typeof target.closest!=='function')return false;
  return Boolean(target.closest('.point,.slice,.choroplethlocation,.box,.violin,.hm,.heatmap'));
}
function singleGeneDatumAt(g,event){
  if(g?.layout?.meta?.bra_kind!=='single_gene_expression')return false;
  return [...(g.querySelectorAll?.('.boxlayer .box,.boxlayer .point')||[])].some(node=>{const box=node.getBoundingClientRect();return event.clientX>=box.left-3&&event.clientX<=box.right+3&&event.clientY>=box.top-3&&event.clientY<=box.bottom+3;});
}
function bindBlankSelectionRestore(g){
  // Single-gene statistic cards are explicitly persistent: blank plot clicks
  // must not dismiss them. They change only with the selected gene or the
  // information-panel toggle.
  if(!g||g.__braBlankSelectionBound||g?.layout?.meta?.bra_kind==='single_gene_expression')return;g.__braBlankSelectionBound=true;let press=null;
  const restore=()=>{if(!g.__braHasSelection&&!g.__braTopVariableIsFocused)return;queueSelectionClear(g,{restoreTopVariable:true});send({type:'bra-specialized-clear-selection'});};
  g.addEventListener('pointerdown',event=>{if(event.button!==0||event.target?.closest?.('.modebar')||event.target?.closest?.('g.colorbar')||event.target?.closest?.('.infolayer .annotation'))return;const time=Date.now();if(eventHitsPlotDatum(event)||singleGeneDatumAt(g,event)){g.__braLastDataClickAt=time;press=null;return;}press={time,x:event.clientX,y:event.clientY,moved:false};},true);
  // Plotly places a drag-cover over the document on pointerdown. The release
  // then lands outside g; listen on window so blank clicks and drags finish.
  window.addEventListener('pointermove',event=>{if(press&&Math.hypot(event.clientX-press.x,event.clientY-press.y)>5)press.moved=true;},true);
  window.addEventListener('pointerup',event=>{const current=press;press=null;if(!current||current.moved||eventHitsPlotDatum(event))return;setTimeout(()=>{if(Number(g.__braLastDataClickAt||0)>=current.time)return;restore();},450);},true);
  window.addEventListener('pointercancel',()=>{press=null;},true);
  if(typeof g.on==='function')g.on('plotly_deselect',()=>{const now=Date.now();if(now<Number(g.__braSuppressDeselectUntil||0)||now-Number(g.__braLastDataClickAt||0)<550)return;restore();});
}
function suppressDeselect(g,delay=1200){if(g)g.__braSuppressDeselectUntil=Math.max(Number(g.__braSuppressDeselectUntil||0),Date.now()+delay);}
function isSelectionOverlay(trace){return ['BRA_RANK_SELECTION_OVERLAY','BRA_SELECTION_OVERLAY'].includes(String(trace?.meta||''));}
async function clearRankSelection(g){
  g.__braRankRevision=Number(g.__braRankRevision||0)+1;
  const annotations=(Array.isArray(g?.layout?.annotations)?g.layout.annotations:[]).filter(item=>String(item?.name||'')!=='BRA_RANK_SELECTION'&&!String(item?.name||'').startsWith('BRA_SELECTION_INFO'));
  const shapes=(Array.isArray(g.layout?.shapes)?g.layout.shapes:[]).filter(item=>String(item?.name||'')!=='BRA_RANK_SELECTION');
  const indices=[];(g.data||[]).forEach((trace,index)=>{if(isSelectionOverlay(trace))indices.push(index);});g.__braPrimarySelection=null;
  if(indices.length)try{await Promise.resolve(Plotly.deleteTraces(g,indices));}catch(_err){}
  try{await Promise.resolve(Plotly.relayout(g,{annotations,shapes}));}catch(_err){}
}
async function clearSelectionVisuals(g,{preserveRevision=false}={}){
  if(!g)return Promise.resolve();if(!preserveRevision)g.__braSelectionRevision=Number(g.__braSelectionRevision||0)+1;
  cancelSelectionHover(g);suppressDeselect(g);const jobs=[],circos=g?.layout?.meta?.bra_kind==='enrichment_circos',selectable=selectionTraceIndices(g);if(circos&&selectable.length){try{jobs.push(Promise.resolve(Plotly.restyle(g,{selectedpoints:selectable.map(()=>null)},selectable)));}catch(_err){}}else if(!circos){for(const index of selectable)try{jobs.push(Promise.resolve(Plotly.restyle(g,{selectedpoints:null},[index])));}catch(_err){}}
  jobs.push(restoreBarTickHighlight(g));g.__braSelectedTraceIndices=new Set();g.__braHasSelection=false;g.__braSelectedGenes=[];await Promise.allSettled(jobs);await clearRankSelection(g);await clearTransientInfo(g);
}
function queueSelectionClear(g,{restoreTopVariable=false}={}){
  if(!g)return Promise.resolve();const revision=Number(g.__braSelectionRevision||0)+1;g.__braSelectionRevision=revision;g.__braHasSelection=false;g.__braSelectedGenes=[];cancelSelectionHover(g);
  const work=async()=>{await clearSelectionVisuals(g,{preserveRevision:true});await resetSingleGeneExpression(g);if(restoreTopVariable){const restored=restoreTopVariableHeatmap(g);if(restored)await Promise.resolve(restored);}};
  g.__braSelectionWork=Promise.resolve(g.__braSelectionWork).catch(()=>{}).then(work);return g.__braSelectionWork;
}
function barAxisKey(trace){
  const horizontal=String(trace?.orientation||'v')==='h',prefix=horizontal?'y':'x',reference=String(horizontal?(trace?.yaxis||'y'):(trace?.xaxis||'x'));
  return reference===prefix?prefix+'axis':prefix+'axis'+reference.slice(1);
}
function restoreBarTickHighlight(g){
  const state=g?.__braBarTickState;if(!state)return Promise.resolve();const update={};
  for(const [axisKey,saved] of Object.entries(state)){update[axisKey+'.tickmode']=saved.tickmode??'auto';update[axisKey+'.tickvals']=saved.tickvals??null;update[axisKey+'.ticktext']=saved.ticktext??null;}
  g.__braBarTickState=null;try{return Promise.resolve(Plotly.relayout(g,update)).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function emphasizeBarCategory(g,traceIndex,pointNumber){
  const trace=g?.data?.[traceIndex],computed=g?._fullData?.[traceIndex]||trace;if(String(trace?.type||computed?.type||'')!=='bar'||!Number.isInteger(Number(pointNumber)))return false;
  const horizontal=String(trace?.orientation||computed?.orientation||'v')==='h',category=(horizontal?computed?.y:computed?.x)?.[Number(pointNumber)];if(category===undefined||category===null)return false;
  const axisKey=barAxisKey(trace),axis=g.layout?.[axisKey]||{},state=g.__braBarTickState||(g.__braBarTickState={});
  if(!state[axisKey])state[axisKey]={tickmode:axis.tickmode,tickvals:Array.isArray(axis.tickvals)?[...axis.tickvals]:null,ticktext:Array.isArray(axis.ticktext)?[...axis.ticktext]:null};
  const saved=state[axisKey],categories=[];
  (g.data||[]).forEach((candidate,index)=>{const decoded=g?._fullData?.[index]||candidate;if(String(candidate?.type||decoded?.type||'')!=='bar'||candidate.visible===false||barAxisKey(candidate)!==axisKey||((String(candidate.orientation||decoded?.orientation||'v')==='h')!==horizontal))return;for(const value of ((horizontal?decoded?.y:decoded?.x)||[])){if(!categories.some(existing=>String(existing)===String(value)))categories.push(value);}});
  const values=saved.tickvals?.length?saved.tickvals:categories,labels=(saved.ticktext?.length===values.length?saved.ticktext:values.map(compactTickHtml)),wanted=String(category);
  const safeTick=value=>String(value??'').includes('<sup>')?String(value):safeHtml(value).replace(/&lt;br\s*\/?&gt;/gi,'<br>');
  try{Plotly.relayout(g,{[axisKey+'.tickmode']:'array',[axisKey+'.tickvals']:values,[axisKey+'.ticktext']:labels.map((label,index)=>String(values[index])===wanted?'<b>'+safeTick(label)+'</b>':safeTick(label))});}catch(_err){}
  return true;
}
function mergeGeneAnnotations(g,incoming){
  if(!g||!incoming||typeof incoming!=='object')return;const store=g.__braGeneAnnotations||(g.__braGeneAnnotations={});for(const [gene,value] of Object.entries(incoming)){const key=String(gene||'').trim();if(!key)continue;const record=value&&typeof value==='object'?value:{product:value};store[key]={...(store[key]||{}),...record};}
}
function annotationForGene(g,gene){
  const store=g?.__braGeneAnnotations||{},key=String(gene||'').trim();if(store[key])return store[key];const folded=key.toLocaleLowerCase();const match=Object.keys(store).find(candidate=>candidate.toLocaleLowerCase()===folded);return match?store[match]:{};
}
function geneProduct(g,gene,fallback=''){
  const annotation=annotationForGene(g,gene),candidates=[annotation?.product,annotation?.Product,annotation?.function,annotation?.gene_function,fallback];for(const candidate of candidates){const text=String(candidate??'').trim();if(text&&!['nan','none','na','null'].includes(text.toLocaleLowerCase()))return text;}return 'Function not available';
}
function pointCoordinates(g,match){
  if(!Number.isInteger(match?.curveNumber)||!Number.isInteger(match?.pointNumber))return null;const trace=g.data?.[match.curveNumber],computed=g._fullData?.[match.curveNumber]||trace,x=computed?.x?.[match.pointNumber],y=computed?.y?.[match.pointNumber];if(x===undefined||x===null||y===undefined||y===null)return null;return {trace,computed,x,y};
}
function persistentSelectionAnnotations(g){
  const primary=g?.__braPrimarySelection,base=(Array.isArray(g?.layout?.annotations)?g.layout.annotations:[]).filter(item=>String(item?.name||'')!=='BRA_RANK_SELECTION'&&!String(item?.name||'').startsWith('BRA_SELECTION_INFO'));if(!primary)return base;
  const point=pointCoordinates(g,primary.match);if(!point)return base;const {trace,x,y}=point,custom=selectionArray(trace?.customdata?.[primary.match.pointNumber])||[],gene=String(primary.gene||custom[1]||''),kind=String(g.layout?.meta?.bra_kind||''),product=geneProduct(g,gene,kind==='de_gene_rank'?custom[6]:'');
  if(kind==='de_gene_rank'){
    const range=g?._fullLayout?.xaxis?.range||[0,Number(x)*2],mid=(Number(range[0])+Number(range[1]))/2,onRight=Number(x)>mid;
    base.push({name:'BRA_RANK_SELECTION',x,y,xref:'x',yref:'y',text:'<b>'+safeHtml(gene)+'</b>',showarrow:false,xshift:onRight?-24:24,yshift:24,xanchor:onRight?'right':'left',yanchor:'bottom',bgcolor:'rgba(255,255,255,0)',borderwidth:0,align:onRight?'right':'left',visible:window.__braShowPlotLabels!==false,font:{color:'#1e2a22',size:14}});
  }
  if(selectionInfoEnabled()&&(kind==='de_gene_rank'||kind==='de_ma')){
    const details=kind==='de_gene_rank'
      ?[`<b>${wrappedHtml(gene,34,2)}</b>`,wrappedHtml(product,42,4),`Contrast: ${wrappedHtml(custom[4]||'',34,2)}`,`Rank: ${statisticText(custom[5]??x)}`,`Signed score: ${statisticText(y)}`]
      :[`<b>${wrappedHtml(gene,34,2)}</b>`,wrappedHtml(product,42,4),`Mean expression: ${statisticText(custom[5]??x)}`,`log₂ fold change: ${statisticText(custom[6]??y)}`,`Adjusted p: ${statisticText(custom[7])}`,`Status: ${wrappedHtml(custom[4]||'',28,2)}`];
    if(kind==='de_gene_rank'){const position=g.__braSelectionPanelPosition||{x:.01,y:.99};base.push({name:'BRA_SELECTION_INFO_PANEL',x:position.x,y:position.y,xref:'paper',yref:'paper',text:details.filter(Boolean).join('<br>'),showarrow:false,xanchor:'left',yanchor:'top',align:'left',bgcolor:'rgba(255,255,255,.97)',bordercolor:'#6a8f7d',borderwidth:1,borderpad:6,font:{color:'#1e2a22',size:12},captureevents:true});}
    else {const toPixel=(axis,value)=>{try{return Number(typeof axis?.d2p==='function'?axis.d2p(value):axis?.l2p?.(value));}catch(_err){return NaN;}},xAxis=g?._fullLayout?.xaxis,yAxis=g?._fullLayout?.yaxis,xPixel=toPixel(xAxis,x),xLength=Number(xAxis?._length)||1,yPixel=toPixel(yAxis,y),yLength=Number(yAxis?._length)||1,onRight=Number.isFinite(xPixel)?xPixel>xLength*.58:false,nearTop=Number.isFinite(yPixel)?yPixel<yLength*.32:false;base.push({name:'BRA_SELECTION_INFO_PANEL',x,y,xref:'x',yref:'y',text:details.filter(Boolean).join('<br>'),showarrow:true,arrowhead:0,arrowwidth:1.2,arrowcolor:'#6a8f7d',ax:onRight?-42:42,ay:nearTop?58:-58,xanchor:onRight?'right':'left',yanchor:nearTop?'top':'bottom',align:'left',bgcolor:'rgba(255,255,255,.97)',bordercolor:'#6a8f7d',borderwidth:1,borderpad:6,font:{color:'#1e2a22',size:12},captureevents:false});}
  }
  return base;
}
function refreshPersistentSelection(g){
  if(!g?.__braPrimarySelection)return Promise.resolve();try{return Promise.resolve(Plotly.relayout(g,{annotations:persistentSelectionAnnotations(g)})).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function markerValueAt(value,index){if(Array.isArray(value)||ArrayBuffer.isView(value))return value[index];return value;}
function topPointMarker(trace,computed,index){
  const marker=trace?.marker||computed?.marker||{},rawColor=markerValueAt(marker.color,index),rawSymbol=markerValueAt(marker.symbol,index),rawSize=Number(markerValueAt(marker.size,index)),color=typeof rawColor==='string'&&rawColor.trim()&&!Number.isFinite(Number(rawColor))?rawColor:'#7b2cbf';
  return {size:Math.max(7,Math.min(14,Number.isFinite(rawSize)?rawSize:9)),symbol:typeof rawSymbol==='string'&&rawSymbol?rawSymbol:'circle',color,opacity:1,line:{width:1.4,color:'#ffffff'}};
}
function pointOverlay(g,match,{ranked=false}={}){
  const point=pointCoordinates(g,match);if(!point)return Promise.resolve();const {trace,computed,x,y}=point,axes={xaxis:trace?.xaxis||'x',yaxis:trace?.yaxis||'y'},meta=ranked?'BRA_RANK_SELECTION_OVERLAY':'BRA_SELECTION_OVERLAY',base={type:'scatter',mode:'markers',x:[x],y:[y],...axes,meta,showlegend:false,hoverinfo:'skip'},overlays=ranked?[{...base,marker:{size:40,symbol:'circle-open',color:'#f0a202',line:{width:4,color:'#f0a202'}}},{...base,marker:{size:27,symbol:'circle-open',color:'#7b2cbf',line:{width:5,color:'#7b2cbf'}}},{...base,marker:{size:8,symbol:'diamond',color:'#7b2cbf',line:{width:1,color:'#7b2cbf'}}}]:[{...base,marker:{size:32,symbol:'circle-open',color:'#f0a202',line:{width:4,color:'#f0a202'}}},{...base,marker:{size:22,symbol:'circle-open',color:'#7b2cbf',line:{width:4,color:'#7b2cbf'}}},{...base,marker:topPointMarker(trace,computed,match.pointNumber)}];
  try{return Promise.resolve(Plotly.addTraces(g,overlays)).catch(()=>{});}catch(_err){return Promise.resolve();}
}
function emphasizeRankedGene(g,match,gene){
  if(g?.layout?.meta?.bra_kind!=='de_gene_rank'||!Number.isInteger(match?.pointNumber))return Promise.resolve();
  const revision=Number(g.__braSelectionRevision||0);g.__braHasSelection=true;g.__braSelectedGenes=[gene];g.__braPrimarySelection={match:{curveNumber:Number(match.curveNumber),pointNumber:Number(match.pointNumber)},gene:String(gene||'')};
  if(revision!==Number(g.__braSelectionRevision||0))return Promise.resolve();return pointOverlay(g,match,{ranked:true}).then(()=>revision===Number(g.__braSelectionRevision||0)?refreshPersistentSelection(g):null);
}
function walkSelection(custom,visit,path=[]){if(!Array.isArray(custom))return false;if(custom[0]==='BRA_SELECTION')return visit(custom,path)===true;for(let index=0;index<custom.length;index++){if(walkSelection(custom[index],visit,path.concat(index)))return true;}return false;}
function traceHasSelections(trace){if(!trace||isSelectionOverlay(trace))return false;let found=false;walkSelection(trace.customdata,()=>{found=true;return true;});return found;}
function selectionTraceIndices(g){const length=(g?.data||[]).length,cache=g?.__braSelectionTraceCache;if(cache?.length===length)return cache.indices;const indices=[];(g?.data||[]).forEach((trace,index)=>{if(traceHasSelections(trace))indices.push(index);});if(g)g.__braSelectionTraceCache={length,indices};return indices;}
async function applyExclusiveSelection(g,byTrace){suppressDeselect(g);const indices=selectionTraceIndices(g),circos=g?.layout?.meta?.bra_kind==='enrichment_circos';if(circos&&indices.length){const selectedpoints=indices.map(index=>[...new Set(byTrace.get(index)||[])]);try{await Promise.resolve(Plotly.restyle(g,{selectedpoints},indices));}catch(_err){}}else if(!circos){for(const index of indices){const points=[...new Set(byTrace.get(index)||[])];try{await Promise.resolve(Plotly.restyle(g,{selectedpoints:[points]},[index]));}catch(_err){}}}g.__braSelectedTraceIndices=new Set([...byTrace.entries()].filter(([_index,points])=>points?.length).map(([index])=>index));}
function highlightGenes(g,requested,annotations={}){
  mergeGeneAnnotations(g,annotations);
  const genes=normalizedGenes(requested);if(!genes.length||!Array.isArray(g.data))return;
  const revision=Number(g.__braSelectionRevision||0)+1;g.__braSelectionRevision=revision;g.__braHasSelection=false;cancelSelectionHover(g);
  const work=async()=>{
    await clearSelectionVisuals(g,{preserveRevision:true});if(revision!==Number(g.__braSelectionRevision||0))return;
    if(genes.length===1){const single=singleGeneExpression(g,genes[0]);if(single){await Promise.resolve(single);return;}}
    const heatmap=selectedGeneHeatmap(g,genes);if(heatmap){await Promise.resolve(heatmap);return;}
    const wanted=new Set(genes),matches=[];
    for(let ti=0;ti<g.data.length;ti++){
      const trace=g.data[ti];if(!trace||trace.visible===false||!Array.isArray(trace.customdata))continue;
      walkSelection(trace.customdata,(custom,path)=>{if(pointGenes(custom).some(gene=>wanted.has(gene))){matches.push({curveNumber:ti,pointNumber:path.length===1?path[0]:(path.length===2?[path[1],path[0]]:path)});}return false;});
    }
    const byTrace=new Map();for(const match of matches){if(Number.isInteger(match.pointNumber)){if(!byTrace.has(match.curveNumber))byTrace.set(match.curveNumber,[]);byTrace.get(match.curveNumber).push(match.pointNumber);}}
    await applyExclusiveSelection(g,byTrace);
    if(revision!==Number(g.__braSelectionRevision||0))return;if(matches.length){g.__braHasSelection=true;g.__braSelectedGenes=genes;const primary=matches[0],firstTrace=g.data?.[primary.curveNumber],isBar=String(firstTrace?.type||'')==='bar',kind=String(g?.layout?.meta?.bra_kind||'');if(kind==='de_gene_rank')await emphasizeRankedGene(g,primary,genes[0]);else if(kind==='de_ma'){g.__braPrimarySelection={match:{curveNumber:primary.curveNumber,pointNumber:primary.pointNumber},gene:genes[0]};await pointOverlay(g,primary);await refreshPersistentSelection(g);}else if(isBar){emphasizeBarCategory(g,primary.curveNumber,primary.pointNumber);}if(revision!==Number(g.__braSelectionRevision||0))return;if(selectionInfoEnabled()&&!['de_gene_rank','de_ma'].includes(kind)&&!isBar)scheduleSelectionHover(g,primary);else cancelSelectionHover(g);}
  };
  g.__braSelectionWork=Promise.resolve(g.__braSelectionWork).catch(()=>{}).then(work);
}
function highlightGene(g,gene,annotations={}){highlightGenes(g,[gene],annotations);}
function selectPlotPayload(g,payload,point=null){
  const revision=Number(g.__braSelectionRevision||0)+1;g.__braSelectionRevision=revision;g.__braHasSelection=false;cancelSelectionHover(g);
  const work=async()=>{
    await clearSelectionVisuals(g,{preserveRevision:true});if(revision!==Number(g.__braSelectionRevision||0))return;
    g.__braHasSelection=true;g.__braSelectedGenes=normalizedGenes(payload.genes?.length?payload.genes:[payload.term_id]);
    const curveNumber=Number(point?.curveNumber),pointNumber=Number(point?.pointNumber),trace=g.data?.[curveNumber],isBar=String(trace?.type||'')==='bar',kind=String(g?.layout?.meta?.bra_kind||''),isRanked=kind==='de_gene_rank',isMA=kind==='de_ma';
    if(Number.isInteger(curveNumber)&&Number.isInteger(pointNumber)){const match={curveNumber,pointNumber};await applyExclusiveSelection(g,new Map([[curveNumber,[pointNumber]]]));if(isBar)emphasizeBarCategory(g,curveNumber,pointNumber);if(isRanked)await emphasizeRankedGene(g,match,g.__braSelectedGenes[0]||payload.term_id);else if(isMA){g.__braPrimarySelection={match,gene:g.__braSelectedGenes[0]||payload.term_id};await pointOverlay(g,match);await refreshPersistentSelection(g);}}
    if(revision!==Number(g.__braSelectionRevision||0))return;send(payload);if(selectionInfoEnabled()&&point&&!isBar&&!isRanked&&!isMA)scheduleSelectionHover(g,{curveNumber,pointNumber:point?.pointNumber});else cancelSelectionHover(g);
  };
  g.__braSelectionWork=Promise.resolve(g.__braSelectionWork).catch(()=>{}).then(work);
}
function graphIsDisplayed(g){return Boolean(g?.isConnected&&g?._fullLayout&&g.getClientRects?.().length);}
function safeResize(g){if(!graphIsDisplayed(g))return Promise.resolve();try{return Promise.resolve(Plotly.Plots.resize(g)).catch(()=>{});}catch(_err){return Promise.resolve();}}
function wrapAxisLabel(value,width,maxLines=4){const text=String(value??'').replace(/<br\s*\/?>/gi,' ').replace(/\s+/g,' ').trim();if(!text||text.length<=width)return text;const words=text.split(' '),lines=[];let line='';for(const word of words){const next=line?line+' '+word:word;if(!line||next.length<=width)line=next;else{lines.push(line);line=word;if(lines.length>=maxLines-1)break;}}if(line&&lines.length<maxLines)lines.push(line);const used=lines.join(' ');if(used.length<text.length&&lines.length)lines[lines.length-1]=lines[lines.length-1].replace(/[.…]*$/,'')+'…';return lines.join('<br>');}
function applyAppearance(g,p){
  const previouslyShowing=window.__braShowSelectionInfo!==false;window.__braShowSelectionInfo=p.showSelectionInfo!==false;if(!window.__braShowSelectionInfo)clearTransientInfo(g);
  window.__braShowPlotLabels=p.showLabels!==false;
  const family=String(p.fontFamily||'Segoe UI'),size=Math.max(6,Math.min(72,Number(p.fontSize)||13)),color=/^#[0-9a-f]{6}$/i.test(String(p.fontColor||''))?p.fontColor:'#1e2a22',weight=p.bold?'700':'400',style=p.italic?'italic':'normal',decoration=p.underline?'underline':'none';
  let css=document.getElementById('braAppliedTypography');if(!css){css=document.createElement('style');css.id='braAppliedTypography';document.head.appendChild(css);}
  document.documentElement.style.setProperty('--bra-plot-font-family',family);document.documentElement.style.setProperty('--bra-plot-font-size',size+'px');document.documentElement.style.setProperty('--bra-plot-font-weight',weight);document.documentElement.style.setProperty('--bra-plot-font-style',style);document.documentElement.style.setProperty('--bra-plot-font-decoration',decoration);
  css.textContent='.js-plotly-plot text,.hoverlayer text{font-family:var(--bra-plot-font-family)!important;font-size:var(--bra-plot-font-size)!important;font-weight:var(--bra-plot-font-weight)!important;font-style:var(--bra-plot-font-style)!important;text-decoration:var(--bra-plot-font-decoration)!important;fill:'+color+'!important;}.js-plotly-plot .bra-selection-info-annotation text{font-size:min(var(--bra-plot-font-size),12px)!important;}';
  const background=/^#[0-9a-f]{6}$/i.test(String(p.backgroundColor||''))?p.backgroundColor:'#ffffff',font={family,size,color},update={'font.family':family,'font.size':size,'font.color':color,'title.text':String(p.plotTitle||''),'paper_bgcolor':background,'plot_bgcolor':background};
  const axisState=window.__braSpecializedAxisTitleState||(window.__braSpecializedAxisTitleState={x:String(g.layout?.xaxis?.title?.text||g.layout?.scene?.xaxis?.title?.text||''),y:String(g.layout?.yaxis?.title?.text||g.layout?.scene?.yaxis?.title?.text||'')}),showAxisTitles=p.showAxisTitles!==false,isCircos=g?.layout?.meta?.bra_kind==='enrichment_circos';
  const requestedX=p.hasAxisTitleOverride===true?String(p.xAxisTitle??''):axisState.x,requestedY=p.hasAxisTitleOverride===true?String(p.yAxisTitle??''):axisState.y;if(!isCircos){if(g.layout?.scene){update['scene.xaxis.title.text']=showAxisTitles?requestedX:'';update['scene.yaxis.title.text']=showAxisTitles?requestedY:'';}else{if(g.layout?.xaxis)update['xaxis.title.text']=showAxisTitles?requestedX:'';if(g.layout?.yaxis)update['yaxis.title.text']=showAxisTitles?requestedY:'';}if(g?.layout?.meta?.bra_kind==='network'){update['xaxis.visible']=showAxisTitles&&Boolean(requestedX.trim());update['xaxis.showticklabels']=false;update['xaxis.showgrid']=false;update['xaxis.zeroline']=false;update['yaxis.visible']=showAxisTitles&&Boolean(requestedY.trim());update['yaxis.showticklabels']=false;update['yaxis.showgrid']=false;update['yaxis.zeroline']=false;}}
  const showGridlines=p.showGridlines===true&&!['enrichment_circos','network','go_cellular_component'].includes(String(g?.layout?.meta?.bra_kind||''));
  for(const key of Object.keys(g.layout||{})){if(/^xaxis\d*$|^yaxis\d*$/.test(key)){update[key+'.tickfont']=font;update[key+'.title.font']=font;update[key+'.showgrid']=showGridlines;}}
  if(g.layout?.polar){update['polar.radialaxis.showgrid']=showGridlines;update['polar.angularaxis.showgrid']=showGridlines;}
  if(g.layout?.legend)update['legend.font']=font;
  const annotations=Array.isArray(g.layout?.annotations)?g.layout.annotations:[];annotations.forEach((annotation,i)=>{const name=String(annotation?.name||''),annotationSize=Number(annotation?.font?.size);update[`annotations[${i}].font`]=name.startsWith('BRA_SELECTION_INFO')?{family,size:Math.min(size,Number.isFinite(annotationSize)?annotationSize:12,12),color}:font;});
  const spacing=window.__braSpecializedAxisSpacingState||(window.__braSpecializedAxisSpacingState={left:Number(g.layout?.margin?.l??g._fullLayout?.margin?.l??70),bottom:Number(g.layout?.margin?.b??g._fullLayout?.margin?.b??58),right:Number(g.layout?.margin?.r??g._fullLayout?.margin?.r??28),top:Number(g.layout?.margin?.t??g._fullLayout?.margin?.t??28),yTickText:{}}),requestedLeft=Number(p.axisLeftSpace)||0,requestedBottom=Number(p.axisBottomSpace)||0,requestedRight=Number(p.axisRightSpace)||0,requestedTop=Number(p.axisTopSpace)||0;if(!spacing.yTickText)spacing.yTickText={};
  update['margin.l']=requestedLeft>0?requestedLeft:spacing.left;
  update['margin.b']=requestedBottom>0?requestedBottom:spacing.bottom;
  const cbState=colorbarState(g);cbState.userMarginRight=requestedRight;
  update['margin.r']=requestedRight>0?requestedRight:(cbState.movedAway?28:spacing.right);
  update['margin.t']=requestedTop>0?requestedTop:spacing.top;
  if(g?.layout?.meta?.bra_kind==='single_gene_expression'){g.__braSingleGeneBaseLeft=Number(update['margin.l'])||65;g.__braSingleGeneBaseRight=Number(update['margin.r'])||35;g.__braSingleGeneInfoKey='';update['title.text']=g.__braHasSelection?'Single-gene expression · '+g.__braSelectedGenes[0]:'';}
  if(!spacing.autoMargins)spacing.autoMargins={};for(const key of Object.keys(g.layout||{})){if(!/^xaxis\d*$|^yaxis\d*$/.test(key))continue;if(!(key in spacing.autoMargins))spacing.autoMargins[key]=g.layout[key]?.automargin??false;const manual=key.startsWith('y')?requestedLeft>0:requestedBottom>0;update[key+'.automargin']=manual?false:spacing.autoMargins[key];}
  for(const key of Object.keys(g.layout||{})){if(!/^yaxis\d*$/.test(key)||!Array.isArray(g.layout?.[key]?.ticktext))continue;if(!(key in spacing.yTickText))spacing.yTickText[key]=[...g.layout[key].ticktext];const original=spacing.yTickText[key];update[key+'.ticktext']=requestedLeft>0?original.map(value=>wrapAxisLabel(value,Math.max(14,Math.min(76,Math.round(requestedLeft/7.5))),4)):[...original];}
  try{Promise.resolve(Plotly.relayout(g,update)).then(()=>safeResize(g)).catch(()=>{});}catch(_err){}
  try{Plotly.restyle(g,{'textfont.family':family,'textfont.size':size,'textfont.color':color});}catch(_err){}
  const showLabels=p.showLabels!==false,state=window.__braSpecializedLabelState||(window.__braSpecializedLabelState={traces:{},axes:{},annotations:{}});
  (g.data||[]).forEach((trace,index)=>{
    if(isSelectionOverlay(trace))return;
    if(!state.traces[index])state.traces[index]={mode:trace.mode,textinfo:trace.textinfo,visible:trace.visible};
    const original=state.traces[index],traceUpdate={};
    if(typeof original.mode==='string'&&original.mode.split('+').includes('text')){
      const parts=original.mode.split('+').filter(part=>part&&part!=='text');
      if(parts.length)traceUpdate.mode=showLabels?original.mode:parts.join('+');
      else traceUpdate.visible=showLabels?(original.visible===undefined?true:original.visible):false;
    }
    if(['pie','sunburst','treemap','funnelarea'].includes(String(trace.type||''))&&original.textinfo!==undefined)traceUpdate.textinfo=showLabels?original.textinfo:'none';
    if(Object.keys(traceUpdate).length)try{Plotly.restyle(g,traceUpdate,[index]);}catch(_err){}
  });
  for(const key of Object.keys(g.layout||{})){
    if(!/^xaxis\d*$|^yaxis\d*$/.test(key))continue;const axis=g.layout[key];
    if(!Array.isArray(axis?.ticktext)||!axis.ticktext.length)continue;
    if(!(key in state.axes))state.axes[key]=axis.showticklabels;
    try{Plotly.relayout(g,{[key+'.showticklabels']:showLabels?(state.axes[key]===undefined?true:state.axes[key]):false});}catch(_err){}
  }
  const plotAnnotations=Array.isArray(g.layout?.annotations)?g.layout.annotations:[];
  plotAnnotations.forEach((annotation,index)=>{const name=String(annotation?.name||'');if(name.startsWith('BRA_SELECTION_INFO')||name==='BRA_SINGLE_GENE_EMPTY')return;if(!(index in state.annotations))state.annotations[index]=annotation.visible;const visible=name==='BRA_RANK_SELECTION'?showLabels:(showLabels?(state.annotations[index]===undefined?true:state.annotations[index]):false);try{Plotly.relayout(g,{[`annotations[${index}].visible`]:visible});}catch(_err){}});
  const nodeColors=(p.nodeColors&&typeof p.nodeColors==='object')?p.nodeColors:{},moduleNames=(p.moduleNames&&typeof p.moduleNames==='object')?p.moduleNames:{},edgeColor=/^#[0-9a-f]{6}$/i.test(String(p.edgeColor||''))?p.edgeColor:'';
  const moduleDisplay=raw=>String(moduleNames[String(raw)]||'').trim()||String(raw);
  const replaceModuleLabel=(value,raw,display)=>{const source=String(value??''),escaped=String(raw).replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),prefixed=new RegExp('Module\\s+'+escaped+'(?=$|[^A-Za-z0-9_])','g'),token=new RegExp('(^|[^A-Za-z0-9_])'+escaped+'(?=$|[^A-Za-z0-9_])','g');if(prefixed.test(source))return source.replace(prefixed,()=>display);return source.replace(token,(_match,before)=>before+display);};
  const renameModuleData=value=>{if(Array.isArray(value))return value.map(renameModuleData);if(value===null||value===undefined)return value;const raw=String(value);return Object.prototype.hasOwnProperty.call(moduleNames,raw)?moduleDisplay(raw):value;};
  const moduleState=window.__braSpecializedModuleNameState||(window.__braSpecializedModuleNameState={traces:{},annotations:{}}),moduleAxes=Array.isArray(g.layout?.meta?.bra_module_axes)?g.layout.meta.bra_module_axes:[];
  moduleAxes.forEach(spec=>{const axis=String(spec?.axis||''),values=Array.isArray(spec?.values)?spec.values:[],tickvals=Array.isArray(spec?.tickvals)&&spec.tickvals.length===values.length?spec.tickvals:values;if(!axis||!values.length)return;const renamed=values.map(moduleDisplay);try{Plotly.relayout(g,{[axis+'.tickvals']:tickvals,[axis+'.ticktext']:renamed});}catch(_err){}});
  plotAnnotations.forEach((annotation,index)=>{const match=/^BRA_MODULE::(.*)$/.exec(String(annotation?.name||''));if(!match)return;const raw=match[1],display=moduleDisplay(raw);if(!(index in moduleState.annotations))moduleState.annotations[index]=String(annotation.text||'');const next=replaceModuleLabel(moduleState.annotations[index],raw,display);try{Plotly.relayout(g,{[`annotations[${index}].text`]:next});}catch(_err){}});
  (g.data||[]).forEach((trace,index)=>{const meta=traceMeta(trace),raw=String(meta.bra_module_raw||'');if(!moduleState.traces[index])moduleState.traces[index]={name:trace.name,text:Array.isArray(trace.text)?[...trace.text]:trace.text,customdata:trace.customdata};const original=moduleState.traces[index],traceUpdate={};if(raw&&String(meta.bra_role||'')!=='node'){const display=moduleDisplay(raw);if(original.name!==undefined)traceUpdate.name=replaceModuleLabel(original.name,raw,display);if(Array.isArray(original.text))traceUpdate.text=[original.text.map(value=>replaceModuleLabel(value,raw,display))];else if(original.text!==undefined)traceUpdate.text=replaceModuleLabel(original.text,raw,display);}/* Plotly.restyle treats a bare outer array as one value per target trace. Double-wrap per-point arrays so customdata/text remain aligned with every point. */if(original.customdata!==undefined)traceUpdate.customdata=[renameModuleData(original.customdata)];if(Object.keys(traceUpdate).length)try{Plotly.restyle(g,traceUpdate,[index]);}catch(_err){}});

  const useCustomColors=p.useCustomColors===true,primary=/^#[0-9a-f]{6}$/i.test(String(p.primaryColor||''))?p.primaryColor:'#2f8f83',secondary=/^#[0-9a-f]{6}$/i.test(String(p.secondaryColor||''))?p.secondaryColor:'#d1775b',palette=String(p.specializedColorScale||'Viridis'),plotStyle=window.__braSpecializedPlotColorState||(window.__braSpecializedPlotColorState={traces:{},coloraxes:{},groupIndices:{}});
  if(!plotStyle.coloraxes)plotStyle.coloraxes={};if(!plotStyle.groupIndices)plotStyle.groupIndices={};
  const markerSequence=value=>Array.isArray(value)?value:(ArrayBuffer.isView(value)?Array.from(value):null);
  (g.data||[]).forEach((trace,index)=>{if(isSelectionOverlay(trace))return;const meta=traceMeta(trace),role=String(meta.bra_role||'');if(role==='node'||role==='edge')return;let saved=plotStyle.traces[index];if(!saved){saved=plotStyle.traces[index]={markerColor:trace.marker?.color,markerColors:Array.isArray(trace.marker?.colors)?[...trace.marker.colors]:trace.marker?.colors,markerColorscale:trace.marker?.colorscale,lineColor:trace.line?.color,fillcolor:trace.fillcolor,colorscale:trace.colorscale,customized:false};}const update={};if(useCustomColors){const colorGroup=String(meta.bra_color_group||'').trim();if(colorGroup&&!Object.prototype.hasOwnProperty.call(plotStyle.groupIndices,colorGroup))plotStyle.groupIndices[colorGroup]=Object.keys(plotStyle.groupIndices).length;const colorIndex=colorGroup?plotStyle.groupIndices[colorGroup]:index,chosen=colorGroup?(colorIndex===0?primary:(colorIndex===1?secondary:(saved.markerColor??trace.marker?.color??primary))):(index%2?secondary:primary),markerValues=markerSequence(trace.marker?.color)||markerSequence(g._fullData?.[index]?.marker?.color),numericMarker=Boolean(markerValues&&markerValues.some(value=>Number.isFinite(Number(value)))),sharedColoraxis=Boolean(trace.marker?.coloraxis);if(String(trace.type||'')==='heatmap'){update.colorscale=palette;}else if(numericMarker&&!sharedColoraxis){update['marker.colorscale']=palette;}else if(Array.isArray(trace.marker?.colors)){update['marker.colors']=[trace.marker.colors.map((_value,i)=>i%2?secondary:primary)];}else if(!numericMarker&&trace.marker&&trace.marker.color!==undefined){update['marker.color']=chosen;}if(trace.line&&trace.line.color!==undefined)update['line.color']=chosen;if(trace.fillcolor!==undefined)update.fillcolor=chosen;saved.customized=true;}else if(saved.customized){update['marker.color']=saved.markerColor===undefined?null:saved.markerColor;update['marker.colors']=saved.markerColors===undefined?null:[saved.markerColors];update['marker.colorscale']=saved.markerColorscale===undefined?null:saved.markerColorscale;update['line.color']=saved.lineColor===undefined?null:saved.lineColor;update.fillcolor=saved.fillcolor===undefined?null:saved.fillcolor;update.colorscale=saved.colorscale===undefined?null:saved.colorscale;saved.customized=false;}if(Object.keys(update).length)try{Plotly.restyle(g,update,[index]);}catch(_err){}});
  const coloraxisUpdate={};for(const key of Object.keys(g.layout||{})){if(!/^coloraxis\d*$/.test(key))continue;if(!(key in plotStyle.coloraxes))plotStyle.coloraxes[key]=g.layout?.[key]?.colorscale;if(useCustomColors)coloraxisUpdate[key+'.colorscale']=palette;else if(plotStyle.coloraxes[key]!==undefined)coloraxisUpdate[key+'.colorscale']=plotStyle.coloraxes[key];}if(Object.keys(coloraxisUpdate).length)try{Plotly.relayout(g,coloraxisUpdate);}catch(_err){}
  const networkState=window.__braSpecializedNetworkStyleState||(window.__braSpecializedNetworkStyleState={traces:{},arrows:{}});
  (g.data||[]).forEach((trace,index)=>{
    const meta=traceMeta(trace),role=String(meta.bra_role||'');
    if(role==='node'){
      const group=String(meta.bra_group||trace.name||'Network node');
      if(!networkState.traces[index])networkState.traces[index]={color:trace.marker?.color,name:trace.name,hovertext:Array.isArray(trace.hovertext)?[...trace.hovertext]:trace.hovertext};
      const requested=/^#[0-9a-f]{6}$/i.test(String(nodeColors[group]||''))?nodeColors[group]:networkState.traces[index].color;
      const rawModule=String(meta.bra_module_raw||''),renamed=rawModule&&String(moduleNames[rawModule]||'').trim(),traceUpdate={};
      if(requested!==undefined)traceUpdate['marker.color']=requested;
      if(rawModule){const display=renamed||rawModule,newName=display,originalHover=networkState.traces[index].hovertext;traceUpdate.name=newName;traceUpdate.legendgroup=newName;if(Array.isArray(originalHover))traceUpdate.hovertext=[originalHover.map(value=>replaceModuleLabel(value,rawModule,display))];}
      if(Object.keys(traceUpdate).length)try{Plotly.restyle(g,traceUpdate,[index]);}catch(_err){}
    }else if(role==='edge'){
      if(!networkState.traces[index])networkState.traces[index]={color:trace.line?.color};
      const requested=edgeColor||networkState.traces[index].color;
      if(requested!==undefined)try{Plotly.restyle(g,{'line.color':requested},[index]);}catch(_err){}
    }
  });
  if(edgeColor){
    plotAnnotations.forEach((annotation,index)=>{if(annotation?.showarrow){if(!(index in networkState.arrows))networkState.arrows[index]=annotation.arrowcolor;try{Plotly.relayout(g,{[`annotations[${index}].arrowcolor`]:edgeColor});}catch(_err){}}});
  }
  if(g?.layout?.meta?.bra_kind==='single_gene_expression')scheduleSingleGeneBoxInfo(g);
  else if(g.__braPrimarySelection)setTimeout(()=>refreshPersistentSelection(g),80);
}
function traceMeta(trace){return trace&&trace.meta&&typeof trace.meta==='object'?trace.meta:{};}
function applyView(g,view){const kind=g?.layout?.meta?.bra_kind;if(!kind||!view)return;
  if(kind==='go_dag'){
    const context=view==='context',branch=context?'':String(view).replace(/^dag_/,'');
    (g.data||[]).forEach((tr,i)=>{const m=traceMeta(tr),show=context?(m.bra_view==='context'):(m.bra_view==='dag'&&m.bra_branch===branch);try{Plotly.restyle(g,{visible:show},[i]);}catch(_err){}});
    const rel=context?{'xaxis.domain':[0,.001],'xaxis2.domain':[.06,.98],'xaxis2.visible':true,'yaxis2.visible':true,'showlegend':false}:{'xaxis.domain':[.03,.78],'xaxis2.domain':[.999,1],'xaxis2.visible':false,'yaxis2.visible':false,'showlegend':true};
    try{Plotly.relayout(g,rel);}catch(_err){}
  } else if(kind==='go_landscape'){
    const target=view==='categories'?'categories':'gene_length';
    (g.data||[]).forEach((tr,i)=>{const m=traceMeta(tr),show=m.bra_view===target;try{Plotly.restyle(g,{visible:show},[i]);}catch(_err){}});
    const meta=g.layout.meta||{},annotations=target==='categories'?(meta.bra_category_annotations||[]):(meta.bra_gene_annotations||[]);
    try{Plotly.relayout(g,{'xaxis.visible':target==='gene_length','yaxis.visible':target==='gene_length','annotations':annotations});}catch(_err){}
  }
  setTimeout(()=>send({type:'bra-specialized-capabilities',capabilities:plotCapabilities(g)}),80);
}
function colorbarCandidates(g){
  const candidates=[],seen=new Set(),add=item=>{if(item&&!seen.has(item.key)){seen.add(item.key);candidates.push(item);}};
  for(const key of Object.keys(g?._fullLayout||{})){if(/^coloraxis\d*$/.test(key)&&g._fullLayout[key]?.showscale!==false)add({kind:'layout',layoutKey:key,key:'layout:'+key});}
  (g?._fullData||[]).forEach((trace,index)=>{const input=g?.data?.[index]||trace;if(trace?.marker?.showscale===true&&!trace?.marker?.coloraxis)add({kind:'trace',traceIndex:index,path:'marker.colorbar',uid:String(trace.uid||input?.uid||''),key:'trace:'+index+':marker.colorbar'});if(trace?.showscale===true&&!trace?.coloraxis)add({kind:'trace',traceIndex:index,path:'colorbar',uid:String(trace.uid||input?.uid||''),key:'trace:'+index+':colorbar'});});
  return candidates;
}
function colorbarPosition(g,descriptor){
  let source,full;if(descriptor.kind==='layout'){source=g?.layout?.[descriptor.layoutKey]?.colorbar;full=g?._fullLayout?.[descriptor.layoutKey]?.colorbar;}else{const input=g?.data?.[descriptor.traceIndex],computed=g?._fullData?.[descriptor.traceIndex];source=descriptor.path==='marker.colorbar'?input?.marker?.colorbar:input?.colorbar;full=descriptor.path==='marker.colorbar'?computed?.marker?.colorbar:computed?.colorbar;}
  const x=Number(source?.x),y=Number(source?.y),fullX=Number(full?.x),fullY=Number(full?.y);return {x:Number.isFinite(x)?x:(Number.isFinite(fullX)?fullX:1.02),y:Number.isFinite(y)?y:(Number.isFinite(fullY)?fullY:.5)};
}
function cartesianDomains(g){const domains={};for(const key of Object.keys(g?._fullLayout||{})){if(!/^xaxis\d*$/.test(key))continue;const input=g?.layout?.[key],full=g?._fullLayout?.[key];if(input?.visible===false||full?.visible===false)continue;const domain=Array.isArray(input?.domain)?input.domain:full?.domain;if(Array.isArray(domain)&&domain.length===2&&domain.every(value=>Number.isFinite(Number(value))))domains[key]=domain.map(Number);}return domains;}
function colorbarState(g){
  if(g.__braColorbarState)return g.__braColorbarState;const full=g?._fullLayout||{},explicitRight=Number(g?.layout?.margin?.r),computedRight=Number(full?.margin?.r),state={marginRight:Number.isFinite(explicitRight)?explicitRight:(Number.isFinite(computedRight)?computedRight:170),bars:{},domains:cartesianDomains(g),applying:false,frame:0};for(const item of colorbarCandidates(g))state.bars[item.key]={descriptor:item,...colorbarPosition(g,item)};g.__braColorbarState=state;return state;
}
function positionColorbar(g,descriptor,x,y){try{return descriptor.kind==='layout'?Promise.resolve(Plotly.relayout(g,{[descriptor.layoutKey+'.colorbar.x']:x,[descriptor.layoutKey+'.colorbar.y']:y})):Promise.resolve(Plotly.restyle(g,{[descriptor.path+'.x']:x,[descriptor.path+'.y']:y},[descriptor.traceIndex]));}catch(_err){return Promise.resolve();}}
function isColorbarEdit(update){return Boolean(update&&typeof update==='object'&&Object.keys(update).some(key=>/(?:^|\.)colorbar\.(?:x|y|xanchor|yanchor)$/.test(String(key))));}
function colorbarOccupiesRight(g,positions){const anchoredRight=positions.some(item=>Number.isFinite(item.x)&&item.x>=.97),size=g?._fullLayout?._size,rect=g?.getBoundingClientRect?.(),bars=[...(g?.querySelectorAll?.('g.colorbar')||[])];if(size&&rect&&bars.length){const paperRight=rect.left+Number(size.l||0)+Number(size.w||0);return anchoredRight||bars.some(bar=>{const box=bar.getBoundingClientRect();return box.width>0&&box.right>=paperRight+12;});}return anchoredRight;}
function domainUpdates(state,expand){const entries=Object.entries(state.domains||{});if(!entries.length)return {};const minimum=Math.min(...entries.map(([,domain])=>domain[0])),maximum=Math.max(...entries.map(([,domain])=>domain[1])),updates={};if(!expand||maximum>=.995||maximum<=minimum){for(const [key,domain] of entries)updates[key+'.domain']=[...domain];return updates;}const scale=(1-minimum)/(maximum-minimum);for(const [key,domain] of entries)updates[key+'.domain']=[minimum+(domain[0]-minimum)*scale,minimum+(domain[1]-minimum)*scale];return updates;}
function colorbarPixelGeometry(g,descriptors){const size=g?._fullLayout?._size,rect=g?.getBoundingClientRect?.();if(!size||!rect||!Number.isFinite(Number(size.w))||Number(size.w)<=0)return null;const groups=[...(g?.querySelectorAll?.('g.colorbar')||[])],paperLeft=rect.left+Number(size.l||0),paperRight=paperLeft+Number(size.w||0),items=descriptors.map((descriptor,index)=>{const classMatch=group=>{const name=String(group?.getAttribute?.('class')||'');return (descriptor.uid&&name.includes(descriptor.uid))||(descriptor.kind==='layout'&&name.includes(descriptor.layoutKey));},group=groups.find(classMatch)||groups[index],box=group?.getBoundingClientRect?.(),position=colorbarPosition(g,descriptor);return {descriptor,position,anchorX:paperLeft+position.x*Number(size.w),box};});return {size,rect,paperLeft,paperRight,items};}
function reflowForColorbars(g){
  const state=colorbarState(g);if(state.applying||!graphIsDisplayed(g))return;const descriptors=colorbarCandidates(g),positions=descriptors.map(item=>colorbarPosition(g,item)),rightOccupied=colorbarOccupiesRight(g,positions),geometry=colorbarPixelGeometry(g,descriptors),requested=Number(state.userMarginRight)||0;let target=requested||(rightOccupied?state.marginRight:28);
  if(!requested&&rightOccupied&&geometry){const rightBars=geometry.items.filter(item=>item.box?.width>0&&item.box.left>=geometry.paperRight-10);if(rightBars.length){const left=Math.min(...rightBars.map(item=>item.box.left));target=Math.max(36,Math.min(state.marginRight,Math.ceil(geometry.rect.right-left+10)));}}
  const anchors=geometry?.items.map(item=>({descriptor:item.descriptor,x:item.anchorX,y:item.position.y}))||[],update={'margin.r':target,...domainUpdates(state,target<state.marginRight-1)};state.movedAway=!rightOccupied;state.applying=true;
  Promise.resolve(Plotly.relayout(g,update)).then(()=>{const size=g?._fullLayout?._size,rect=g?.getBoundingClientRect?.();if(!size||!rect||!Number.isFinite(Number(size.w))||Number(size.w)<=0)return;const paperLeft=rect.left+Number(size.l||0),width=Number(size.w);return Promise.all(anchors.map(item=>positionColorbar(g,item.descriptor,Math.max(-2,Math.min(3,(item.x-paperLeft)/width)),item.y)));}).then(()=>safeResize(g)).catch(()=>{}).finally(()=>{state.applying=false;});
}
function queueColorbarReflow(g){const state=colorbarState(g);if(state.frame)cancelAnimationFrame(state.frame);state.frame=requestAnimationFrame(()=>{state.frame=requestAnimationFrame(()=>{state.frame=0;reflowForColorbars(g);});});}
function resetColorbars(g){const state=g?.__braColorbarState;if(!state||!graphIsDisplayed(g))return;state.applying=true;Promise.resolve(Plotly.relayout(g,{'margin.r':state.marginRight,...domainUpdates(state,false)})).then(()=>{for(const saved of Object.values(state.bars))positionColorbar(g,saved.descriptor,saved.x,saved.y);return safeResize(g);}).catch(()=>{}).finally(()=>{state.applying=false;});}
function bindColorbarPointerDrag(g){
  if(!g||g.__braColorbarPointerBound)return;g.__braColorbarPointerBound=true;
  g.addEventListener('pointerdown',event=>{
    if(event.button!==0||event.target?.closest?.('.modebar'))return;const group=event.target?.closest?.('g.colorbar');if(!group)return;
    const groups=[...(g.querySelectorAll?.('g.colorbar')||[])],index=groups.indexOf(group),candidates=colorbarCandidates(g),className=String(group.getAttribute?.('class')||''),descriptor=candidates.find(item=>item.uid&&className.includes(item.uid))||candidates.find(item=>item.kind==='layout'&&className.includes(item.layoutKey))||candidates[index];if(index<0||!descriptor)return;
    const start=colorbarPosition(g,descriptor),size=g?._fullLayout?._size,graphRect=g.getBoundingClientRect(),barRect=group.getBoundingClientRect(),paperWidth=Math.max(1,Number(size?.w)||g.clientWidth||1),paperHeight=Math.max(1,Number(size?.h)||g.clientHeight||1),paperLeft=graphRect.left+Number(size?.l||0),anchorX=paperLeft+start.x*paperWidth,leftOffset=barRect.left-anchorX,rightOffset=barRect.right-anchorX,minX=Math.max(-2,(graphRect.left+4-paperLeft-leftOffset)/paperWidth),maxX=Math.min(3,(graphRect.right-4-paperLeft-rightOffset)/paperWidth),drag={id:event.pointerId,descriptor,startX:event.clientX,startY:event.clientY,valueX:start.x,valueY:start.y,paperWidth,paperHeight,minX:Math.min(minX,maxX),maxX:Math.max(minX,maxX),moved:false};
    g.__braColorbarDrag=drag;const state=colorbarState(g);state.dragging=true;g.classList.add('bra-colorbar-dragging');
    const move=moveEvent=>{const current=g.__braColorbarDrag;if(!current||moveEvent.pointerId!==current.id)return;const dx=moveEvent.clientX-current.startX,dy=moveEvent.clientY-current.startY;if(Math.hypot(dx,dy)>3)current.moved=true;const x=Math.max(current.minX,Math.min(current.maxX,current.valueX+dx/current.paperWidth)),y=Math.max(.08,Math.min(.92,current.valueY-dy/current.paperHeight));positionColorbar(g,current.descriptor,x,y);moveEvent.preventDefault();moveEvent.stopPropagation();};
    const stop=upEvent=>{const current=g.__braColorbarDrag;if(!current||upEvent.pointerId!==current.id)return;window.removeEventListener('pointermove',move,true);window.removeEventListener('pointerup',stop,true);window.removeEventListener('pointercancel',stop,true);g.__braColorbarDrag=null;g.classList.remove('bra-colorbar-dragging');const state=colorbarState(g);state.dragging=false;if(current.moved)queueColorbarReflow(g);upEvent.preventDefault();upEvent.stopPropagation();};
    window.addEventListener('pointermove',move,true);window.addEventListener('pointerup',stop,true);window.addEventListener('pointercancel',stop,true);event.preventDefault();event.stopPropagation();
  },true);
}
function bindColorbarDrag(g){
  if(!g||g.__braColorbarDragBound||typeof g.on!=='function')return;g.__braColorbarDragBound=true;colorbarState(g);bindColorbarPointerDrag(g);
  // Keep Plotly's native edit events as a fallback, while the pointer handler
  // supplies consistent dragging for scattergl, heatmap, polar, and DAG bars.
  g.on('plotly_relayout',update=>{const state=colorbarState(g);if(!state.applying&&!state.dragging&&isColorbarEdit(update))queueColorbarReflow(g);});
  g.on('plotly_restyle',update=>{const state=colorbarState(g),payload=Array.isArray(update)?update[0]:update;if(!state.dragging&&isColorbarEdit(payload))queueColorbarReflow(g);});
}
function numericRange(axis){if(!axis||!Array.isArray(axis.range)||axis.range.length!==2)return null;const a=Number(axis.range[0]),b=Number(axis.range[1]);return Number.isFinite(a)&&Number.isFinite(b)?[a,b]:null;}
function polarZoom(g,factor){const polar=g?.layout?.polar;if(!polar)return false;const domain=polar.domain||{},x=Array.isArray(domain.x)?domain.x:[0,1],y=Array.isArray(domain.y)?domain.y:[0,1],state=window.__braPolarZoomState||(window.__braPolarZoomState={original:{x:[...x],y:[...y]},current:{x:[...x],y:[...y]}}),grow=factor<1?1.10:0.91,cx=(state.current.x[0]+state.current.x[1])/2,cy=(state.current.y[0]+state.current.y[1])/2,ow=state.original.x[1]-state.original.x[0],oh=state.original.y[1]-state.original.y[0],w=Math.max(ow*.72,Math.min(Math.min(.92,ow*1.55),(state.current.x[1]-state.current.x[0])*grow)),h=Math.max(oh*.72,Math.min(Math.min(.96,oh*1.28),(state.current.y[1]-state.current.y[0])*grow)),nx=[Math.max(.01,cx-w/2),Math.min(.99,cx+w/2)],ny=[Math.max(.01,cy-h/2),Math.min(.99,cy+h/2)];if(nx[1]-nx[0]<w){if(nx[0]<=.01)nx[1]=.01+w;else nx[0]=.99-w;}if(ny[1]-ny[0]<h){if(ny[0]<=.01)ny[1]=.01+h;else ny[0]=.99-h;}state.current={x:nx,y:ny};try{Plotly.relayout(g,{'polar.domain.x':nx,'polar.domain.y':ny});}catch(_err){}return true;}
function shiftedDomain(domain,delta){const width=domain[1]-domain[0],lo=Math.max(.01,Math.min(.99-width,domain[0]+delta));return [lo,lo+width];}
function bindPolarPan(g){if(g?.layout?.meta?.bra_kind!=='enrichment_circos')return;const domain=g.layout?.polar?.domain||{},initialX=Array.isArray(domain.x)?domain.x:[0,1],initialY=Array.isArray(domain.y)?domain.y:[0,1];if(!window.__braPolarZoomState)window.__braPolarZoomState={original:{x:[...initialX],y:[...initialY]},current:{x:[...initialX],y:[...initialY]}};let drag=null;window.__braPolarPanEnabled=true;g.style.cursor='grab';g.addEventListener('pointerdown',event=>{if(!window.__braPolarPanEnabled||event.button!==0||event.target?.closest?.('.modebar'))return;const state=window.__braPolarZoomState;if(!state)return;drag={id:event.pointerId,x:event.clientX,y:event.clientY,startX:[...state.current.x],startY:[...state.current.y]};try{g.setPointerCapture(event.pointerId);}catch(_err){}g.style.cursor='grabbing';event.preventDefault();});g.addEventListener('pointermove',event=>{if(!drag||event.pointerId!==drag.id)return;const rect=g.getBoundingClientRect(),nx=shiftedDomain(drag.startX,(event.clientX-drag.x)/Math.max(1,rect.width)),ny=shiftedDomain(drag.startY,-(event.clientY-drag.y)/Math.max(1,rect.height)),state=window.__braPolarZoomState;state.current={x:nx,y:ny};try{Plotly.relayout(g,{'polar.domain.x':nx,'polar.domain.y':ny});}catch(_err){}event.preventDefault();});const stop=event=>{if(!drag||event.pointerId!==drag.id)return;drag=null;g.style.cursor=window.__braPolarPanEnabled?'grab':'';};g.addEventListener('pointerup',stop);g.addEventListener('pointercancel',stop);}
function zoom(g,factor){if(g?.layout?.meta?.bra_kind==='enrichment_circos'&&polarZoom(g,factor))return;const update={};for(const key of ['xaxis','yaxis','xaxis2','yaxis2']){const axis=g?._fullLayout?.[key],r=numericRange(axis);if(!r)continue;const mid=(r[0]+r[1])/2,half=(r[1]-r[0])*factor/2;update[key+'.range']=[mid-half,mid+half];}if(Object.keys(update).length)try{Plotly.relayout(g,update);}catch(_err){}}
function resetView(g){resetColorbars(g);const topVariable=g?.layout?.meta?.bra_kind==='top_variable_gene_heatmap';Promise.resolve(queueSelectionClear(g,{restoreTopVariable:topVariable})).then(()=>{if(topVariable)return;const polarState=window.__braPolarZoomState;if(g?.layout?.meta?.bra_kind==='enrichment_circos'&&polarState){polarState.current={x:[...polarState.original.x],y:[...polarState.original.y]};try{Plotly.relayout(g,{'polar.domain.x':polarState.original.x,'polar.domain.y':polarState.original.y});}catch(_err){}return;}try{Plotly.relayout(g,{'xaxis.autorange':true,'yaxis.autorange':true,'xaxis2.autorange':true,'yaxis2.autorange':true});}catch(_err){}});}
function command(g,p){const cmd=p.command;if(['pan','zoom','select','lasso'].includes(cmd)){window.__braPolarPanEnabled=cmd==='pan';if(g?.layout?.meta?.bra_kind==='enrichment_circos')g.style.cursor=cmd==='pan'?'grab':'crosshair';try{Plotly.relayout(g,{dragmode:cmd});}catch(_err){}}else if(cmd==='zoomIn')zoom(g,.72);else if(cmd==='zoomOut')zoom(g,1.38);else if(cmd==='reset')resetView(g);else if(cmd==='clearSelection')queueSelectionClear(g,{restoreTopVariable:true});else if(cmd==='export'){const fmt=document.getElementById('braExportFormat'),wanted=String(p.format||'').toLowerCase();if(fmt&&[...fmt.options].some(option=>option.value===wanted))fmt.value=wanted;window.BRA_exportCurrentPlot?.(p);}}
function fitEmbedded(g){if(!(window.parent&&window.parent!==window)||!graphIsDisplayed(g))return;document.documentElement.style.height='100%';document.documentElement.style.overflow='hidden';document.body.style.height='100%';document.body.style.overflow='hidden';const h=Math.max(300,window.innerHeight-2);try{Promise.resolve(Plotly.relayout(g,{height:h,autosize:true})).then(()=>safeResize(g)).catch(()=>{});}catch(_err){}}
function networkAppearance(g){const nodeGroups=[],seen=new Set();let edgeColor='';for(const trace of (g.data||[])){const meta=traceMeta(trace),role=String(meta.bra_role||'');if(role==='node'){const name=String(meta.bra_group||trace.name||'Network node');if(!seen.has(name)){seen.add(name);nodeGroups.push({name,color:String(trace.marker?.color||'#75b9cf')});}}else if(role==='edge'&&!edgeColor)edgeColor=String(trace.line?.color||'#52665b');}return {nodeGroups,edgeColor};}
function plotCapabilities(g){
  const visible=(g?.data||[]).filter(trace=>trace&&trace.visible!==false&&trace.visible!=='legendonly'),kind=String(g?.layout?.meta?.bra_kind||''),filename=decodeURIComponent(String(location.pathname||'').split('/').pop()||'').toLowerCase(),selectionInfo=['single_gene_expression','de_gene_rank','de_ma'].includes(kind)||/(?:single_gene_expression|de_gene_rank|ma)_interactive/.test(filename),traceLabels=visible.some(trace=>String(trace.mode||'').split('+').includes('text')||(['pie','sunburst','treemap','funnelarea'].includes(String(trace.type||'').toLowerCase())&&String(trace.textinfo||'none')!=='none')),annotationLabels=(g?.layout?.annotations||[]).some(item=>{const name=String(item?.name||'');return !name.startsWith('BRA_SELECTION_INFO')&&name!=='BRA_RANK_SELECTION'&&name!=='BRA_SINGLE_GENE_EMPTY';}),axisLabels=Object.keys(g?.layout||{}).some(key=>/^xaxis\d*$|^yaxis\d*$/.test(key)&&Array.isArray(g.layout[key]?.ticktext)&&g.layout[key].ticktext.length),hasX=Boolean(g.layout?.xaxis||g.layout?.scene?.xaxis),hasY=Boolean(g.layout?.yaxis||g.layout?.scene?.yaxis),axisTitle=axis=>String(typeof axis?.title==='string'?axis.title:(axis?.title?.text||'')),xTitle=axisTitle(g.layout?.xaxis||g.layout?.scene?.xaxis),yTitle=axisTitle(g.layout?.yaxis||g.layout?.scene?.yaxis),gradientTypes=new Set(['heatmap','contour','histogram2d','histogram2dcontour','surface','mesh3d','cone','streamtube','isosurface','volume','choropleth','choroplethmap','choroplethmapbox']),numericColors=value=>{const sequence=Array.isArray(value)?value:(ArrayBuffer.isView(value)?Array.from(value):null);return Boolean(sequence?.length&&sequence.some(item=>Number.isFinite(Number(item))));},hasGradient=visible.some(trace=>gradientTypes.has(String(trace.type||'').toLowerCase())||numericColors(trace.marker?.color)||Boolean(trace.marker?.coloraxis||trace.coloraxis)),gradientBlocked=/(?:^|\/)(?:ma_interactive|pca_interactive|sample_pca_3d_interactive|sample_expression_distributions_interactive|sample_dendrogram_interactive|source_of_variation_interactive|de_pvalue_histogram_interactive|single_gene_expression_interactive)\.html$/.test(filename);
  return {selectionInfo,labels:kind==='de_gene_rank'||traceLabels||annotationLabels||axisLabels,gridlines:!['enrichment_circos','network','go_cellular_component'].includes(kind)&&hasX&&hasY,axisTitles:kind!=='enrichment_circos',xTitle,yTitle,gradientPalette:hasGradient&&!gradientBlocked};
}
function bindCellLabelDrag(g){
  if(g?.layout?.meta?.bra_kind!=='go_cellular_component')return;
  const mark=()=>{const groups=[...(g.querySelectorAll?.('.infolayer .annotation')||[])],annotations=Array.isArray(g.layout?.annotations)?g.layout.annotations:[];groups.forEach((group,index)=>{group.classList.toggle('bra-cell-label-draggable',String(annotations[index]?.name||'').startsWith('BRA_CELL::'));});};
  mark();if(g.__braCellLabelDragBound)return;g.__braCellLabelDragBound=true;g.on('plotly_afterplot',mark);
  g.addEventListener('pointerdown',event=>{
    if(event.button!==0||event.target?.closest?.('.modebar'))return;const group=event.target?.closest?.('.infolayer .annotation');if(!group)return;const groups=[...(g.querySelectorAll?.('.infolayer .annotation')||[])],index=groups.indexOf(group),annotation=g.layout?.annotations?.[index];if(index<0||!String(annotation?.name||'').startsWith('BRA_CELL::'))return;
    const movableX=Number(annotation.showarrow?annotation.ax:annotation.x),movableY=Number(annotation.showarrow?annotation.ay:annotation.y),start={id:event.pointerId,index,x:event.clientX,y:event.clientY,valueX:movableX,valueY:movableY,moved:false,showarrow:Boolean(annotation.showarrow)};if(!Number.isFinite(movableX)||!Number.isFinite(movableY))return;g.__braCellLabelDrag=start;event.preventDefault();event.stopPropagation();
    const move=moveEvent=>{const drag=g.__braCellLabelDrag;if(!drag||moveEvent.pointerId!==drag.id)return;const xr=numericRange(g?._fullLayout?.xaxis),yr=numericRange(g?._fullLayout?.yaxis),xLength=Math.max(1,Number(g?._fullLayout?.xaxis?._length)||Number(g?._fullLayout?._size?.w)||1),yLength=Math.max(1,Number(g?._fullLayout?.yaxis?._length)||Number(g?._fullLayout?._size?.h)||1);if(!xr||!yr)return;const dx=moveEvent.clientX-drag.x,dy=moveEvent.clientY-drag.y;if(Math.hypot(dx,dy)>3)drag.moved=true;const nextX=drag.valueX+dx*(xr[1]-xr[0])/xLength,nextY=drag.valueY-dy*(yr[1]-yr[0])/yLength,prefix=`annotations[${drag.index}]`,update=drag.showarrow?{[prefix+'.ax']:nextX,[prefix+'.ay']:nextY}:{[prefix+'.x']:nextX,[prefix+'.y']:nextY};try{Plotly.relayout(g,update);}catch(_err){}moveEvent.preventDefault();moveEvent.stopPropagation();};
    const stop=upEvent=>{const drag=g.__braCellLabelDrag;if(!drag||upEvent.pointerId!==drag.id)return;window.removeEventListener('pointermove',move,true);window.removeEventListener('pointerup',stop,true);window.removeEventListener('pointercancel',stop,true);g.__braCellLabelDrag=null;if(!drag.moved){const selections=g.layout?.meta?.bra_annotation_selections,payload=Array.isArray(selections)?parseSelection(selections[drag.index]):null;if(payload){g.__braCellClickHandledUntil=Date.now()+300;selectPlotPayload(g,payload);}}upEvent.preventDefault();upEvent.stopPropagation();};
    window.addEventListener('pointermove',move,true);window.addEventListener('pointerup',stop,true);window.addEventListener('pointercancel',stop,true);
  },true);
}
function markSelectionInfoAnnotations(g){
  const groups=[...(g?.querySelectorAll?.('.infolayer .annotation')||[])],annotations=Array.isArray(g?.layout?.annotations)?g.layout.annotations:[];
  groups.forEach((group,index)=>group.classList.toggle('bra-selection-info-annotation',String(annotations[index]?.name||'').startsWith('BRA_SELECTION_INFO')));
}
function bindSelectionPanelDrag(g){
  if(g?.layout?.meta?.bra_kind!=='de_gene_rank'||g.__braSelectionPanelDragBound)return;g.__braSelectionPanelDragBound=true;
  const mark=()=>{const groups=[...(g.querySelectorAll?.('.infolayer .annotation')||[])],annotations=Array.isArray(g.layout?.annotations)?g.layout.annotations:[];groups.forEach((group,index)=>group.classList.toggle('bra-cell-label-draggable',String(annotations[index]?.name||'')==='BRA_SELECTION_INFO_PANEL'));};
  mark();g.on('plotly_afterplot',mark);
  g.addEventListener('pointerdown',event=>{
    if(event.button!==0||event.target?.closest?.('.modebar'))return;const group=event.target?.closest?.('.infolayer .annotation');if(!group)return;const groups=[...(g.querySelectorAll?.('.infolayer .annotation')||[])],index=groups.indexOf(group),annotation=g.layout?.annotations?.[index];if(index<0||String(annotation?.name||'')!=='BRA_SELECTION_INFO_PANEL')return;
    const start={id:event.pointerId,index,x:event.clientX,y:event.clientY,valueX:Number(annotation.x),valueY:Number(annotation.y)};if(!Number.isFinite(start.valueX)||!Number.isFinite(start.valueY))return;g.__braSelectionPanelDrag=start;event.preventDefault();event.stopPropagation();
    const move=moveEvent=>{const drag=g.__braSelectionPanelDrag;if(!drag||moveEvent.pointerId!==drag.id)return;const size=g?._fullLayout?._size||{},width=Math.max(1,Number(size.w)||g.clientWidth||1),height=Math.max(1,Number(size.h)||g.clientHeight||1),nextX=Math.max(0,Math.min(1,drag.valueX+(moveEvent.clientX-drag.x)/width)),nextY=Math.max(0,Math.min(1,drag.valueY-(moveEvent.clientY-drag.y)/height)),prefix=`annotations[${drag.index}]`;g.__braSelectionPanelPosition={x:nextX,y:nextY};try{Plotly.relayout(g,{[prefix+'.x']:nextX,[prefix+'.y']:nextY});}catch(_err){}moveEvent.preventDefault();moveEvent.stopPropagation();};
    const stop=upEvent=>{const drag=g.__braSelectionPanelDrag;if(!drag||upEvent.pointerId!==drag.id)return;window.removeEventListener('pointermove',move,true);window.removeEventListener('pointerup',stop,true);window.removeEventListener('pointercancel',stop,true);g.__braSelectionPanelDrag=null;upEvent.preventDefault();upEvent.stopPropagation();};
    window.addEventListener('pointermove',move,true);window.addEventListener('pointerup',stop,true);window.addEventListener('pointercancel',stop,true);
  },true);
}
function bind(){
  const g=graph();if(!g||typeof g.on!=='function'){setTimeout(bind,50);return;}if(g.__braSpecializedEventsBound)return;
  g.__braSpecializedEventsBound=true;rememberTopVariableHeatmap(g);fitEmbedded(g);bindColorbarDrag(g);bindCellLabelDrag(g);bindSelectionPanelDrag(g);bindBlankSelectionRestore(g);markSelectionInfoAnnotations(g);g.on('plotly_afterplot',()=>markSelectionInfoAnnotations(g));
  if(g.layout?.meta?.bra_kind==='single_gene_expression'){
    g.on('plotly_hover',event=>{const point=event?.points?.[0];if(point?.x!==undefined)g.__braBoxCondition=String(point.x);});
    g.on('plotly_afterplot',()=>scheduleSingleGeneBoxInfo(g));
    g.addEventListener('mouseleave',()=>scheduleSingleGeneBoxInfo(g));
  }
  g.on('plotly_click',event=>{
    // A pinned box hover leaves _hoverdata set even over empty space. Its
    // synthetic click must not cancel a physical background deselection.
    if(g.layout?.meta?.bra_kind==='single_gene_expression')return;
    const point=event?.points?.[0];if(!point)return;const trace=g.data?.[Number(point.curveNumber)],fallback=trace?.customdata?.[Number(point.pointNumber)],payload=parseSelection(point.customdata??fallback);
    if(payload){g.__braLastDataClickAt=Date.now();selectPlotPayload(g,payload,point);}
  });
  g.on('plotly_clickannotation',event=>{if(Date.now()<Number(g.__braCellClickHandledUntil||0))return;g.__braLastDataClickAt=Date.now();const index=Number(event?.index),selections=g?.layout?.meta?.bra_annotation_selections;if(Number.isInteger(index)&&Array.isArray(selections)){const payload=parseSelection(selections[index]);if(payload)selectPlotPayload(g,payload);}});
  if(g?.layout?.meta?.bra_kind==='enrichment_circos'){g.addEventListener('wheel',event=>{event.preventDefault();polarZoom(g,event.deltaY<0?.72:1.38);},{passive:false});bindPolarPan(g);}
  window.addEventListener('message',event=>{const p=event?.data;if(!p)return;if(p.type==='bra-highlight-gene')highlightGene(g,p.gene,p.annotations);else if(p.type==='bra-highlight-genes')highlightGenes(g,p.genes,p.annotations);else if(p.type==='bra-gene-annotations'){mergeGeneAnnotations(g,p.annotations);if(g.__braPrimarySelection)refreshPersistentSelection(g);}else if(p.type==='bra-specialized-appearance')applyAppearance(g,p);else if(p.type==='bra-specialized-command')command(g,p);else if(p.type==='bra-specialized-view')applyView(g,p.view);});
  window.addEventListener('resize',()=>fitEmbedded(g));send({type:'bra-specialized-ready',...networkAppearance(g),capabilities:plotCapabilities(g)});
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',bind);else bind();
})();
</script>"""
        text = text.replace('</head>', css + '</head>', 1)
        text = text.replace('<body>', '<body>' + toolbar, 1)
        text = text.replace('</body>', export_script + selection_script + '</body>', 1)
        output_path.write_text(text, encoding="utf-8")
    except OSError:
        pass


def safe_neg_log10(values: pd.Series) -> pd.Series:
    numeric = pd.to_numeric(values, errors="coerce").fillna(1.0)
    numeric = numeric.clip(lower=np.finfo(float).tiny, upper=1.0)
    return -np.log10(numeric)


def _wrap_plot_label(value: object, width: int = 32, max_lines: int = 3) -> str:
    """Wrap a long biological category into a small number of Plotly lines."""
    words = str(value or "").split()
    if not words:
        return ""
    lines: list[str] = []
    current = ""
    for word in words:
        proposed = word if not current else current + " " + word
        if len(proposed) <= width or not current:
            current = proposed
        else:
            lines.append(current)
            current = word
            if len(lines) >= max_lines - 1:
                break
    if current and len(lines) < max_lines:
        lines.append(current)
    consumed = " ".join(lines)
    original = " ".join(words)
    if len(consumed) < len(original) and lines:
        lines[-1] = (lines[-1][: max(1, width - 1)].rstrip() + "…")
    return "<br>".join(lines)


def _wrap_full_plot_label(value: object, width: int = 32) -> str:
    """Wrap a biological label without replacing any of it with an ellipsis."""
    words = str(value or "").split()
    if not words:
        return ""
    lines: list[str] = []
    current = ""
    for word in words:
        proposed = word if not current else current + " " + word
        if len(proposed) <= width or not current:
            current = proposed
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return "<br>".join(lines)


VOLCANO_COLORSCALE = [
    [0.0, "#2c7bb6"],
    [0.25, "#75c8a5"],
    [0.5, "#ffffbf"],
    [0.75, "#fdae61"],
    [1.0, "#d7191c"],
]


def build_volcano_figure(
    result: pd.DataFrame,
    lfc_col: str,
    p_col: str,
    *,
    lfc_cutoff: float = 1.0,
    p_cutoff: float = 0.05,
    label_count: int = 5,
    minimum_point_size: float = 5.0,
    maximum_point_size: float = 18.0,
) -> go.Figure:
    """Build the suite's publication-style interactive volcano plot."""
    frame = result.copy()
    frame[lfc_col] = pd.to_numeric(frame[lfc_col], errors="coerce")
    frame[p_col] = pd.to_numeric(frame[p_col], errors="coerce")
    frame = frame.dropna(subset=[lfc_col, p_col]).copy()
    frame[p_col] = frame[p_col].clip(lower=np.finfo(float).tiny, upper=1.0)
    frame["minus_log10_p"] = -np.log10(frame[p_col])
    frame["direction"] = "Not significant"
    significant = frame[p_col].le(p_cutoff) & frame[lfc_col].abs().ge(lfc_cutoff)
    frame.loc[significant & frame[lfc_col].gt(0), "direction"] = "Upregulated"
    frame.loc[significant & frame[lfc_col].lt(0), "direction"] = "Downregulated"

    score = frame["minus_log10_p"].clip(upper=frame["minus_log10_p"].quantile(0.99))
    if score.max() > score.min():
        marker_size = minimum_point_size + (maximum_point_size - minimum_point_size) * (
            (score - score.min()) / (score.max() - score.min())
        )
    else:
        marker_size = pd.Series((minimum_point_size + maximum_point_size) / 2, index=frame.index)

    gene = frame["gene_id"].astype(str) if "gene_id" in frame else frame.index.astype(str)
    raw_p_col = first_existing(frame, ["pvalue", "PValue", "P.Value"])
    adjusted_col = first_existing(frame, ["padj", "FDR", "adj.P.Val"])
    raw_values = pd.to_numeric(frame[raw_p_col], errors="coerce") if raw_p_col else frame[p_col]
    adjusted_values = pd.to_numeric(frame[adjusted_col], errors="coerce") if adjusted_col else frame[p_col]
    customdata = np.column_stack([
        np.full(len(frame), "BRA_SELECTION", dtype=object),
        gene,
        gene,
        gene,
        raw_values,
        adjusted_values,
        frame["direction"],
    ])

    fig = go.Figure()
    fig.add_trace(
        go.Scatter(
            x=frame[lfc_col],
            y=frame["minus_log10_p"],
            mode="markers",
            name="Genes",
            customdata=customdata,
            marker={
                "size": marker_size,
                "color": frame[lfc_col],
                "colorscale": VOLCANO_COLORSCALE,
                "cmid": 0,
                "showscale": True,
                "colorbar": {"title": "log₂ fold change"},
                "opacity": 0.76,
                "line": {"width": 0.35, "color": "rgba(45,55,48,0.45)"},
            },
            hovertemplate=(
                "<b>%{customdata[1]}</b><br>"
                "log₂ fold change: %{x:.4g}<br>"
                "−log₁₀(selected p): %{y:.4g}<br>"
                "raw p-value: %{customdata[4]:.4g}<br>"
                "adjusted p-value: %{customdata[5]:.4g}<br>"
                "status: %{customdata[6]}<br>"
                "<extra></extra>"
            ),
        )
    )

    threshold_y = -math.log10(max(p_cutoff, np.finfo(float).tiny))
    fig.add_vline(x=-lfc_cutoff, line_dash="dash", line_color="#3f4942", line_width=1)
    fig.add_vline(x=lfc_cutoff, line_dash="dash", line_color="#3f4942", line_width=1)
    fig.add_hline(y=threshold_y, line_dash="dashdot", line_color="#3f4942", line_width=1)

    labelled_parts = []
    for direction, ascending in (("Downregulated", True), ("Upregulated", False)):
        candidates = frame.loc[frame["direction"].eq(direction)].sort_values(
            ["minus_log10_p", lfc_col], ascending=[False, ascending]
        )
        labelled_parts.append(candidates.head(max(0, int(label_count))))
    labelled = pd.concat(labelled_parts) if labelled_parts else frame.iloc[0:0]
    for index, (_, row) in enumerate(labelled.iterrows()):
        is_up = row[lfc_col] > 0
        fig.add_annotation(
            x=row[lfc_col],
            y=row["minus_log10_p"],
            text=str(row.get("gene_id", row.name)),
            showarrow=True,
            arrowhead=0,
            arrowwidth=1,
            arrowcolor="#465149",
            ax=(18 if is_up else -18) + (index % 2) * (5 if is_up else -5),
            ay=-12 - (index % 3) * 5,
            bgcolor="rgba(255,255,255,0.72)",
            borderpad=1,
        )

    up_count = int(frame["direction"].eq("Upregulated").sum())
    down_count = int(frame["direction"].eq("Downregulated").sum())
    fig.add_annotation(x=0.18, y=0.96, xref="paper", yref="paper", text=f"Down {down_count}", showarrow=True, ax=55, ay=0, arrowhead=2, arrowcolor="#4b9bc2", font={"color": "#4b9bc2", "size": 14})
    fig.add_annotation(x=0.82, y=0.96, xref="paper", yref="paper", text=f"Up {up_count}", showarrow=True, ax=-55, ay=0, arrowhead=2, arrowcolor="#d94b42", font={"color": "#d94b42", "size": 14})
    fig.update_layout(
        title="Interactive volcano plot",
        plot_bgcolor="#ffffff",
        paper_bgcolor="#ffffff",
        xaxis_title="log₂ fold change",
        yaxis_title=f"−log₁₀({p_col})",
        hovermode="closest",
        legend={"orientation": "h", "y": -0.18},
    )
    return fig


def first_existing(df: pd.DataFrame, names: Iterable[str]) -> str | None:
    for name in names:
        if name in df.columns:
            return name
    return None


def plot_selection(config: dict, defaults: set[str]) -> set[str]:
    """Return selected plot identifiers, preserving legacy all-plot behaviour."""
    raw = config.get("plots")
    if raw is None or raw == "" or (isinstance(raw, (list, tuple, set)) and len(raw) == 0):
        return set(defaults)
    if isinstance(raw, str):
        return {raw}
    return {str(item) for item in raw}


def _track_text(value: object) -> str:
    """Return a single-line value that is safe inside a quoted track attribute."""
    return " ".join(str(value).replace('"', "'").split())


def write_de_bedgraph(config: dict, result: pd.DataFrame | None = None) -> str | None:
    """Write an IGV-ready, signed gene-level log2-fold-change bedGraph track.

    The coordinate table follows the suite's documented convention: ``start``
    and ``end`` are 1-based inclusive gene coordinates. bedGraph is 0-based and
    half-open, so a gene at 1..900 is written as 0..900. Every tested gene with
    a finite fold change is retained; statistical significance remains available
    in the DE table and in the companion audit table.
    """
    annotation_value = str(config.get("annotation_file") or "").strip()
    if not annotation_value:
        print(
            "BEDGRAPH\tSKIPPED\tSupply the optional gene-coordinate table "
            "(gene_id, seqid, start, end) to create the IGV differential-expression track."
        )
        return None

    annotation_path = Path(annotation_value)
    if not annotation_path.is_file():
        raise ValueError(f"The gene-coordinate table was not found: {annotation_path}")

    output_dir = Path(config["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    if result is None:
        result_path = Path(config.get("result_file") or (output_dir / "differential_expression.tsv"))
        result = normalize_id_column(read_table(str(result_path)))
    else:
        result = normalize_id_column(result.copy())

    lfc_col = first_existing(result, ["log2FoldChange", "logFC", "log2fc"])
    if not lfc_col:
        raise ValueError("The DE result does not contain a log2-fold-change column for bedGraph export.")
    padj_col = first_existing(result, ["padj", "FDR", "adj.P.Val"])

    annotation = normalize_id_column(read_table(str(annotation_path)))
    seq_col = first_existing(annotation, ["seqid", "contig", "chromosome", "sequence", "Chr", "chr"])
    start_col = first_existing(annotation, ["start", "Start", "gene_start"])
    end_col = first_existing(annotation, ["end", "End", "gene_end"])

    # RNA Processing historically exported descriptive gene_metadata.tsv without
    # coordinates, while the adjacent featureCounts SAF file retained the exact
    # normalized intervals.  Reuse that SAF automatically so old projects can
    # still obtain the IGV track without asking the user for another file.
    if not (seq_col and start_col and end_col):
        saf_path = annotation_path.parent / "features.saf"
        if saf_path.is_file():
            saf = read_table(str(saf_path))
            saf_id = first_existing(saf, ["GeneID", "gene_id", "gene", "ID"])
            saf_seq = first_existing(saf, ["Chr", "seqid", "contig", "chromosome", "sequence"])
            saf_start = first_existing(saf, ["Start", "start", "gene_start"])
            saf_end = first_existing(saf, ["End", "end", "gene_end"])
            if saf_id and saf_seq and saf_start and saf_end:
                annotation = saf[[saf_id, saf_seq, saf_start, saf_end]].copy()
                annotation.columns = ["gene_id", "seqid", "start", "end"]
                seq_col, start_col, end_col = "seqid", "start", "end"
                print(f"BEDGRAPH_COORDINATES\tUsing RNA Processing SAF coordinates: {saf_path}")

    missing = [
        label
        for label, column in (("seqid", seq_col), ("start", start_col), ("end", end_col))
        if not column
    ]
    if missing:
        raise ValueError(
            "The gene-coordinate table cannot create a bedGraph because it lacks: "
            + ", ".join(missing)
            + ". Required columns are gene_id, seqid, start, and end."
        )

    coordinates = annotation[["gene_id", seq_col, start_col, end_col]].copy()
    coordinates.columns = ["gene_id", "seqid", "start", "end"]
    coordinates["gene_id"] = coordinates["gene_id"].astype(str).str.strip()
    coordinates["seqid"] = coordinates["seqid"].astype(str).str.strip()
    coordinates["start"] = pd.to_numeric(coordinates["start"], errors="coerce")
    coordinates["end"] = pd.to_numeric(coordinates["end"], errors="coerce")
    coordinates["start_1based"] = coordinates[["start", "end"]].min(axis=1)
    coordinates["end_1based"] = coordinates[["start", "end"]].max(axis=1)
    valid_coordinates = (
        coordinates["gene_id"].ne("")
        & coordinates["seqid"].ne("")
        & coordinates["start_1based"].notna()
        & coordinates["end_1based"].notna()
        & (coordinates["start_1based"] >= 1)
        & (coordinates["end_1based"] >= coordinates["start_1based"])
        & coordinates["start_1based"].eq(np.floor(coordinates["start_1based"]))
        & coordinates["end_1based"].eq(np.floor(coordinates["end_1based"]))
    )
    invalid_coordinate_rows = int((~valid_coordinates).sum())
    coordinates = coordinates.loc[valid_coordinates, ["gene_id", "seqid", "start_1based", "end_1based"]]
    if coordinates.empty:
        raise ValueError("The gene-coordinate table contains no valid 1-based inclusive intervals.")

    # Multiple CDS/exon rows for one gene are collapsed to the full gene span.
    coordinate_rows_before_collapse = len(coordinates)
    coordinates = (
        coordinates.groupby(["gene_id", "seqid"], as_index=False, sort=False)
        .agg(start_1based=("start_1based", "min"), end_1based=("end_1based", "max"))
    )
    collapsed_coordinate_rows = coordinate_rows_before_collapse - len(coordinates)

    result["gene_id"] = result["gene_id"].astype(str).str.strip()
    result[lfc_col] = pd.to_numeric(result[lfc_col], errors="coerce")
    result_columns = ["gene_id", lfc_col]
    if padj_col:
        result[padj_col] = pd.to_numeric(result[padj_col], errors="coerce")
        result_columns.append(padj_col)
        result = result.sort_values(padj_col, na_position="last", kind="stable")
    duplicate_result_ids = int(result["gene_id"].duplicated(keep="first").sum())
    result = result[result_columns].drop_duplicates("gene_id", keep="first")

    coordinate_matches = coordinates.merge(result, on="gene_id", how="inner", validate="many_to_one")
    coordinate_matched_gene_ids = set(coordinate_matches["gene_id"])
    nonfinite_lfc_gene_count = int(
        coordinate_matches.loc[~np.isfinite(coordinate_matches[lfc_col]), "gene_id"].nunique()
    )
    mapped = coordinate_matches[np.isfinite(coordinate_matches[lfc_col])].copy()
    if mapped.empty:
        raise ValueError(
            "No DE-result gene IDs matched valid gene-coordinate IDs. "
            "Use the same gene identifiers in the count matrix and coordinate table."
        )

    mapped["chromStart"] = mapped["start_1based"].astype(np.int64) - 1
    mapped["chromEnd"] = mapped["end_1based"].astype(np.int64)
    mapped = mapped[mapped["chromEnd"] > mapped["chromStart"]].copy()
    mapped = mapped.sort_values(["seqid", "chromStart", "chromEnd", "gene_id"], kind="stable")

    overlap_count = 0
    for _, group in mapped.groupby("seqid", sort=False):
        previous_end = -1
        for start, end in zip(group["chromStart"], group["chromEnd"]):
            if int(start) < previous_end:
                overlap_count += 1
            previous_end = max(previous_end, int(end))

    test_level = _track_text(config.get("test_level") or "test")
    reference_level = _track_text(config.get("reference_level") or "reference")
    track_name = _track_text(f"{test_level} vs {reference_level} log2FC")
    description = _track_text(
        f"Signed gene-level log₂ fold change ({test_level} versus {reference_level}); "
        "positive is upregulated and negative is downregulated"
    )
    output_path = output_dir / "differential_expression_log2fc.bedGraph"
    with output_path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            f'track type=bedGraph name="{track_name}" description="{description}" '
            "visibility=full color=34,139,34 altColor=220,20,60 "
            "alwaysZero=on graphType=bar\n"
        )
        for row in mapped.itertuples(index=False):
            handle.write(f"{row.seqid}\t{row.chromStart}\t{row.chromEnd}\t{getattr(row, lfc_col):.8g}\n")

    audit = mapped.rename(columns={lfc_col: "log2FoldChange"}).copy()
    if padj_col:
        audit = audit.rename(columns={padj_col: "adjusted_p_value"})
        alpha = float(config.get("padj_cutoff", 0.05))
        lfc_cutoff = float(config.get("lfc_cutoff", 0.0))
        significant = (
            audit["adjusted_p_value"].notna()
            & (audit["adjusted_p_value"] <= alpha)
            & (audit["log2FoldChange"].abs() >= lfc_cutoff)
        )
        audit["de_status"] = "Not significant"
        audit.loc[significant & (audit["log2FoldChange"] > 0), "de_status"] = "Upregulated"
        audit.loc[significant & (audit["log2FoldChange"] < 0), "de_status"] = "Downregulated"
    audit_columns = [
        "gene_id",
        "seqid",
        "start_1based",
        "end_1based",
        "chromStart",
        "chromEnd",
        "log2FoldChange",
    ]
    for optional_column in ("adjusted_p_value", "de_status"):
        if optional_column in audit.columns:
            audit_columns.append(optional_column)
    audit_path = output_dir / "differential_expression_igv_track_data.tsv"
    audit[audit_columns].to_csv(audit_path, sep="\t", index=False, lineterminator="\n")

    tested_gene_ids = {gene_id for gene_id in result["gene_id"] if gene_id}
    mapped_gene_count = len(coordinate_matched_gene_ids)
    exported_gene_count = int(mapped["gene_id"].nunique())
    unmapped_tested_gene_count = len(tested_gene_ids - coordinate_matched_gene_ids)
    summary_path = output_dir / "analysis_summary.json"
    try:
        summary = {}
        if summary_path.is_file():
            with summary_path.open("r", encoding="utf-8-sig") as handle:
                summary = json.load(handle)
        summary["igv_bedgraph"] = {
            "file": output_path.name,
            "audit_file": audit_path.name,
            "value": "signed gene-level log2FoldChange",
            "coordinate_system": "0-based half-open (converted from 1-based inclusive input)",
            "mapped_genes": mapped_gene_count,
            "exported_genes": exported_gene_count,
            "unmapped_tested_genes": unmapped_tested_gene_count,
            "nonfinite_log2fc_genes": nonfinite_lfc_gene_count,
            "overlapping_intervals": overlap_count,
        }
        with summary_path.open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(summary, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
    except (OSError, ValueError, TypeError) as exc:
        print(f"BEDGRAPH\tWARNING\tCould not update analysis_summary.json: {exc}")

    print(f"BEDGRAPH\t{output_path}")
    print(f"BEDGRAPH_AUDIT\t{audit_path}")
    print(
        "BEDGRAPH_MAPPING\t"
        f"mapped_genes={mapped_gene_count}\t"
        f"exported_genes={exported_gene_count}\t"
        f"unmapped_tested_genes={unmapped_tested_gene_count}\t"
        f"nonfinite_log2fc_genes={nonfinite_lfc_gene_count}\t"
        f"invalid_coordinate_rows={invalid_coordinate_rows}\t"
        f"collapsed_coordinate_rows={collapsed_coordinate_rows}\t"
        f"duplicate_result_ids={duplicate_result_ids}\t"
        f"overlapping_intervals={overlap_count}"
    )
    if overlap_count:
        print(
            "BEDGRAPH\tWARNING\tOverlapping gene coordinates were preserved as separate gene-level bars; "
            "inspect overlapping loci together with the genome annotation in IGV."
        )
    return str(output_path)


def de_plots(config: dict) -> list[str]:
    output_dir = Path(config["output_dir"])
    result_path = config.get("result_file") or str(output_dir / "differential_expression.tsv")
    normalized_path = config.get("normalized_file") or str(output_dir / "normalized_counts.tsv")
    result = normalize_id_column(read_table(result_path))
    normalized = normalize_id_column(read_table(normalized_path)).set_index("gene_id")
    # The report already provides the suite's richer configurable Volcano and
    # Circos views. Keep one canonical MA implementation here and do not create
    # duplicate Volcano/circular-genome companion plots.
    selected = plot_selection(config, {"ma", "pca"})
    selected.discard("volcano")
    selected.discard("circular")
    created: list[str] = []

    # The IGV log2FC bedGraph is useful only when a valid gene-coordinate table
    # is available.  Differential-expression statistics and the other plots do
    # not depend on genomic coordinates, so coordinate problems must never turn
    # an otherwise successful DE run into a failed job.
    try:
        bedgraph_path = write_de_bedgraph(config, result)
        if bedgraph_path:
            created.append(bedgraph_path)
    except (ValueError, OSError, KeyError) as exc:
        print(
            "BEDGRAPH\tSKIPPED\t"
            "The optional IGV differential-expression track was not created: "
            f"{exc}"
        )

    lfc_col = first_existing(result, ["log2FoldChange", "logFC", "log2fc"])
    padj_col = first_existing(result, ["padj", "FDR", "adj.P.Val"])
    p_col = first_existing(result, ["pvalue", "PValue", "P.Value"])
    mean_col = first_existing(result, ["baseMean", "logCPM", "AveExpr", "mean_expression"])
    if not lfc_col:
        raise ValueError("The DE result does not contain a log2-fold-change column.")
    if not padj_col:
        padj_col = p_col
    if not padj_col:
        raise ValueError("The DE result does not contain an adjusted or raw p-value column.")

    lfc_cutoff = float(config.get("lfc_cutoff", 1.0))
    padj_cutoff = float(config.get("padj_cutoff", 0.05))
    point_size = float(config.get("plot_point_size", 6))
    result[lfc_col] = pd.to_numeric(result[lfc_col], errors="coerce")
    result[padj_col] = pd.to_numeric(result[padj_col], errors="coerce")
    result["minus_log10_adjusted_p"] = safe_neg_log10(result[padj_col])
    result["status"] = "Not significant"
    result.loc[(result[padj_col] <= padj_cutoff) & (result[lfc_col] >= lfc_cutoff), "status"] = "Upregulated"
    result.loc[(result[padj_col] <= padj_cutoff) & (result[lfc_col] <= -lfc_cutoff), "status"] = "Downregulated"

    hover_cols = ["gene_id"]
    for name in [mean_col, lfc_col, padj_col]:
        if name and name not in hover_cols:
            hover_cols.append(name)

    if "ma" in selected and mean_col:
        result[mean_col] = pd.to_numeric(result[mean_col], errors="coerce")
        plot_frame = result.dropna(subset=["gene_id", mean_col, lfc_col]).copy()
        plot_frame = plot_frame.loc[plot_frame[mean_col].gt(0)]
        status_colours = {
            "Downregulated": "#43a047",
            "Not significant": "#c9d0cc",
            "Upregulated": "#ef5350",
        }
        fig = go.Figure()
        for status_name in ("Downregulated", "Not significant", "Upregulated"):
            frame = plot_frame.loc[plot_frame["status"].eq(status_name)]
            if frame.empty:
                continue
            custom = [
                ["BRA_SELECTION", str(gene), str(gene), str(gene), status_name, mean_value, fold_change, adjusted_p]
                for gene, mean_value, fold_change, adjusted_p in zip(
                    frame["gene_id"], frame[mean_col], frame[lfc_col], frame[padj_col]
                )
            ]
            fig.add_trace(go.Scatter(
                x=frame[mean_col], y=frame[lfc_col], mode="markers", name=status_name,
                customdata=custom,
                marker={"size": point_size, "color": status_colours[status_name], "opacity": 0.78},
                selected={"marker": {"size": max(point_size + 5, 11), "opacity": 1, "color": "#7b2cbf"}},
                unselected={"marker": {"opacity": 0.22}},
                hovertemplate=(
                    "<b>%{customdata[1]}</b><br>Mean expression: %{x:.4g}"
                    "<br>log₂ fold change: %{y:.4g}<br>Adjusted p: %{customdata[7]:.3g}"
                    "<br>Status: %{customdata[4]}<extra></extra>"
                ),
            ))
        fig.add_hline(y=0, line_width=1.2, line_color="#6f7d74")
        fig.update_layout(
            title="Interactive MA plot",
            xaxis={"title": "Mean expression", "type": "log", "automargin": True},
            yaxis={"title": "log₂ fold change", "automargin": True},
            legend={"orientation": "h", "y": 1.08},
            meta={"bra_kind": "de_ma"},
            margin={"l": 82, "r": 45, "t": 82, "b": 70},
        )
        write_plot(fig, output_dir / "ma_interactive.html")
        created.append("ma_interactive.html")

    matrix = normalized.apply(pd.to_numeric, errors="coerce").fillna(0.0)
    matrix = np.log2(matrix + 1.0)

    if "pca" in selected:
        variances = matrix.var(axis=1)
        pca_gene_limit = max(50, int(config.get("pca_top_genes", 1000)))
        keep = variances.nlargest(min(pca_gene_limit, len(variances))).index
        sample_matrix = matrix.loc[keep].T
        if sample_matrix.shape[0] < 2 or sample_matrix.shape[1] < 1:
            raise ValueError("PCA requires at least two samples and one variable gene.")
        centered = sample_matrix - sample_matrix.mean(axis=0)
        u, singular_values, _ = np.linalg.svd(centered.to_numpy(), full_matrices=False)
        component_count = min(2, len(singular_values))
        scores = u[:, :component_count] * singular_values[:component_count]
        if component_count == 1:
            scores = np.column_stack([scores[:, 0], np.zeros(scores.shape[0])])
        explained = (singular_values**2) / max(np.sum(singular_values**2), np.finfo(float).tiny)
        if len(explained) == 1:
            explained = np.array([explained[0], 0.0])
        pca = pd.DataFrame({"sample_id": sample_matrix.index.astype(str), "PC1": scores[:, 0], "PC2": scores[:, 1]})
        metadata_path = config.get("metadata_file")
        color_col = None
        if metadata_path and os.path.exists(metadata_path):
            metadata = read_table(metadata_path)
            sample_col = config.get("sample_column") or metadata.columns[0]
            metadata[sample_col] = metadata[sample_col].astype(str)
            pca = pca.merge(metadata, left_on="sample_id", right_on=sample_col, how="left")
            requested = config.get("condition_column")
            if requested in pca.columns:
                color_col = requested
        fig = px.scatter(
            pca,
            x="PC1",
            y="PC2",
            color=color_col,
            text="sample_id",
            hover_data=list(pca.columns),
            labels={"PC1": f"PC1 ({explained[0] * 100:.1f}%)", "PC2": f"PC2 ({explained[1] * 100:.1f}%)"},
            title="Sample PCA",
        )
        fig.update_traces(textposition="top center", marker={"size": point_size + 2})
        write_plot(fig, output_dir / "pca_interactive.html")
        created.append("pca_interactive.html")

    return created


def circular_plot(config: dict) -> str:
    output_dir = Path(config["output_dir"])
    result_path = config.get("result_file") or str(output_dir / "differential_expression.tsv")
    result = normalize_id_column(read_table(result_path))
    lfc_col = first_existing(result, ["log2FoldChange", "logFC", "log2fc"])
    padj_col = first_existing(result, ["padj", "FDR", "adj.P.Val", "pvalue", "PValue", "P.Value"])
    if not lfc_col:
        raise ValueError("A log2-fold-change column is required for a circular plot.")
    result[lfc_col] = pd.to_numeric(result[lfc_col], errors="coerce").fillna(0.0)
    if padj_col:
        result[padj_col] = pd.to_numeric(result[padj_col], errors="coerce")
    else:
        result["padj"] = np.nan
        padj_col = "padj"

    annotation_path = config.get("annotation_file")
    if annotation_path and os.path.exists(annotation_path):
        ann = normalize_id_column(read_table(annotation_path))
        start_col = first_existing(ann, ["start", "Start", "gene_start"])
        end_col = first_existing(ann, ["end", "End", "gene_end"])
        seq_col = first_existing(ann, ["seqid", "contig", "chromosome", "sequence"])
        if (not start_col or not end_col) and Path(annotation_path).parent.joinpath("features.saf").is_file():
            saf = normalize_id_column(read_table(str(Path(annotation_path).parent / "features.saf")))
            saf_seq = first_existing(saf, ["Chr", "seqid", "contig", "chromosome", "sequence"])
            saf_start = first_existing(saf, ["Start", "start", "gene_start"])
            saf_end = first_existing(saf, ["End", "end", "gene_end"])
            saf_strand = first_existing(saf, ["Strand", "strand"])
            if saf_seq and saf_start and saf_end:
                ann = saf
                seq_col, start_col, end_col = saf_seq, saf_start, saf_end
                if saf_strand:
                    ann = ann.rename(columns={saf_strand: "strand"})
        if start_col and end_col:
            ann[start_col] = pd.to_numeric(ann[start_col], errors="coerce")
            ann[end_col] = pd.to_numeric(ann[end_col], errors="coerce")
            ann["midpoint"] = (ann[start_col] + ann[end_col]) / 2.0
            if not seq_col:
                ann["seqid"] = "genome"
                seq_col = "seqid"
            ann = ann.sort_values([seq_col, "midpoint"]).copy()
            offsets: dict[str, float] = {}
            current = 0.0
            gap = max(1.0, ann["midpoint"].max() * 0.015)
            for seq_id, group in ann.groupby(seq_col, sort=False):
                offsets[str(seq_id)] = current
                current += float(group[end_col].max()) + gap
            ann["linear_position"] = [offsets[str(seq)] + pos for seq, pos in zip(ann[seq_col], ann["midpoint"])]
            ann["linear_start"] = [offsets[str(seq)] + pos for seq, pos in zip(ann[seq_col], ann[start_col])]
            ann["linear_end"] = [offsets[str(seq)] + pos for seq, pos in zip(ann[seq_col], ann[end_col])]
            total = max(float(ann["linear_end"].max()), 1.0)
            ann["theta"] = ann["linear_position"] / total * 360.0
            ann["theta_start"] = ann["linear_start"] / total * 360.0
            ann["theta_end"] = ann["linear_end"] / total * 360.0
            strand_col = first_existing(ann, ["strand", "Strand", "orientation"])
            merge_columns = ["gene_id", "theta", "theta_start", "theta_end", seq_col, start_col, end_col]
            if strand_col and strand_col not in merge_columns:
                merge_columns.append(strand_col)
            merged = result.merge(ann[merge_columns], on="gene_id", how="left")
        else:
            raise ValueError("Circos requires genomic start/end coordinates; RNA Processing should supply gene_coordinates.tsv or features.saf.")
    else:
        raise ValueError("Circos requires a gene-coordinate table. Use gene_coordinates.tsv from RNA Processing.")

    merged = merged.dropna(subset=["theta"]).copy()
    max_abs = max(float(np.nanmax(np.abs(merged[lfc_col].to_numpy()))) if len(merged) else 1.0, 1.0)
    baseline = max_abs + 1.5
    merged["radius"] = baseline + merged[lfc_col]
    merged["significance"] = safe_neg_log10(merged[padj_col])
    hover = ["gene_id", lfc_col, padj_col, seq_col]
    if start_col and end_col:
        hover.extend([start_col, end_col])
    custom = merged[hover].astype(str).to_numpy()
    hover_template = "Gene %{customdata[0]}<br>log₂ FC %{customdata[1]}<br>Adjusted p %{customdata[2]}<br>Sequence %{customdata[3]}"
    if start_col and end_col:
        hover_template += "<br>Start %{customdata[4]}<br>End %{customdata[5]}"
    hover_template += "<extra></extra>"
    fig = go.Figure()
    fig.add_trace(
        go.Scatterpolar(
            theta=np.linspace(0, 360, 361),
            r=np.repeat(baseline, 361),
            mode="lines",
            line={"width": 1.4, "color": "#68756d"},
            hoverinfo="skip",
            name="log₂ FC = 0",
        )
    )
    # Signed radial DE bars make up/down direction visible without conflating it with genomic strand.
    up_theta: list[float | None] = []
    up_r: list[float | None] = []
    down_theta: list[float | None] = []
    down_r: list[float | None] = []
    for angle, value in zip(merged["theta"], merged[lfc_col]):
        target = baseline + float(value)
        if float(value) >= 0:
            up_theta.extend([float(angle), float(angle), None]); up_r.extend([baseline, target, None])
        else:
            down_theta.extend([float(angle), float(angle), None]); down_r.extend([baseline, target, None])
    fig.add_trace(go.Scatterpolar(theta=up_theta, r=up_r, mode="lines", line={"color": "#e34a42", "width": 2}, name="Upregulated", hoverinfo="skip"))
    fig.add_trace(go.Scatterpolar(theta=down_theta, r=down_r, mode="lines", line={"color": "#3f78c5", "width": 2}, name="Downregulated", hoverinfo="skip"))

    strand_col = first_existing(merged, ["strand", "Strand", "orientation"])
    if strand_col and "theta_start" in merged.columns and "theta_end" in merged.columns:
        inner = max(0.45, baseline - max_abs - 0.55)
        plus_theta: list[float | None] = []; plus_r: list[float | None] = []
        minus_theta: list[float | None] = []; minus_r: list[float | None] = []
        for row in merged.itertuples(index=False):
            strand = str(getattr(row, strand_col))
            a = float(getattr(row, "theta_start")); b = float(getattr(row, "theta_end"))
            if strand == "+":
                plus_theta.extend([a, b, None]); plus_r.extend([inner + 0.12, inner + 0.12, None])
            elif strand == "-":
                minus_theta.extend([a, b, None]); minus_r.extend([inner, inner, None])
        if plus_theta:
            fig.add_trace(go.Scatterpolar(theta=plus_theta, r=plus_r, mode="lines", line={"color": "#3b7f5f", "width": 5}, name="+ strand genes", hoverinfo="skip"))
        if minus_theta:
            fig.add_trace(go.Scatterpolar(theta=minus_theta, r=minus_r, mode="lines", line={"color": "#7653a6", "width": 5}, name="− strand genes", hoverinfo="skip"))

    fig.add_trace(
        go.Scatterpolar(
            theta=merged["theta"],
            r=merged["radius"],
            mode="markers",
            marker={
                "size": np.clip(4 + merged["significance"] * 0.7, 4, 12),
                "color": np.where(merged[lfc_col] >= 0, "#e34a42", "#3f78c5"),
                "opacity": 0.82,
                "line": {"width": 0.4, "color": "#ffffff"},
            },
            customdata=custom,
            hovertemplate=hover_template,
            name="Genes",
            showlegend=False,
        )
    )
    fig.update_layout(
        title="Interactive Circos-style differential-expression plot",
        polar={
            "radialaxis": {"visible": False},
            "angularaxis": {"direction": "clockwise", "rotation": 90, "showticklabels": False},
        },
        showlegend=True,
    )
    output_file = Path(config.get("output_file") or (output_dir / "circular_genome_interactive.html"))
    write_plot(fig, output_file)
    return str(output_file)


def gene_range_plot(config: dict) -> str:
    output_dir = Path(config["output_dir"])
    normalized_path = config.get("normalized_file") or str(output_dir / "normalized_counts.tsv")
    normalized = normalize_id_column(read_table(normalized_path)).set_index("gene_id")
    normalized = normalized.apply(pd.to_numeric, errors="coerce").fillna(0.0)
    genes = list(normalized.index.astype(str))

    def resolve(value: str | int | None, default: int) -> int:
        if value is None or str(value).strip() == "":
            return default
        text = str(value).strip()
        try:
            index = int(text)
            return max(0, min(len(genes) - 1, index - 1))
        except ValueError:
            if text not in genes:
                raise ValueError(f"Gene '{text}' was not found in the normalized matrix.")
            return genes.index(text)

    start = resolve(config.get("start_gene"), 0)
    end = resolve(config.get("end_gene"), min(9, len(genes) - 1))
    if end < start:
        start, end = end, start
    if end - start + 1 > 100:
        raise ValueError("The interactive gene-range bar plot is limited to 100 genes per view.")
    selected = normalized.iloc[start : end + 1]
    transformed = np.log2(selected + 1.0)
    mode = config.get("aggregation", "condition_mean")
    metadata_path = config.get("metadata_file")
    condition_col = config.get("condition_column")
    sample_col = config.get("sample_column")

    if mode == "condition_mean" and metadata_path and os.path.exists(metadata_path):
        metadata = read_table(metadata_path)
        if not sample_col:
            sample_col = metadata.columns[0]
        if not condition_col or condition_col not in metadata.columns:
            condition_col = metadata.columns[1] if len(metadata.columns) > 1 else sample_col
        metadata[sample_col] = metadata[sample_col].astype(str)
        available = [sample for sample in transformed.columns.astype(str) if sample in set(metadata[sample_col])]
        if not available:
            raise ValueError("No expression-matrix samples match the selected metadata sample-ID column.")
        long = transformed[available].reset_index().melt(id_vars="gene_id", var_name="sample_id", value_name="log2_expression")
        long = long.merge(metadata[[sample_col, condition_col]], left_on="sample_id", right_on=sample_col, how="left")
        plot_data = (
            long.groupby(["gene_id", condition_col], as_index=False)["log2_expression"]
            .agg(log2_expression="mean", standard_deviation="std", replicate_count="size")
        )
        plot_data["standard_deviation"] = plot_data["standard_deviation"].fillna(0.0)
        series_col = condition_col
        error_column = "standard_deviation"
        title = f"Genes {start + 1} to {end + 1}: mean expression by condition"
    else:
        plot_data = transformed.reset_index().melt(id_vars="gene_id", var_name="sample_id", value_name="log2_expression")
        series_col = "sample_id"
        error_column = None
        title = f"Genes {start + 1} to {end + 1}: expression by sample"

    fig = px.bar(
        plot_data,
        x="gene_id",
        y="log2_expression",
        color=series_col,
        error_y=error_column,
        barmode="group",
        hover_data=list(plot_data.columns),
        labels={"gene_id": "Gene", "log2_expression": "log₂ normalized expression + 1"},
        title=title,
    )
    fig.update_xaxes(categoryorder="array", categoryarray=list(selected.index.astype(str)))
    output_file = Path(config.get("output_file") or (output_dir / f"gene_range_{start + 1}_{end + 1}.html"))
    write_plot(fig, output_file)
    return str(output_file)


def parse_gene_set(value: object) -> set[str]:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return set()
    text = str(value).replace("/", ",").replace(";", ",")
    return {item.strip() for item in text.split(",") if item.strip()}



def _split_gene_values(value: object) -> list[str]:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return []
    return [item.strip() for item in re.split(r"[,;/|]+", str(value)) if item.strip()]


def _read_flexible_table(path: str | os.PathLike[str]) -> pd.DataFrame:
    source = Path(path)
    suffix = source.suffix.lower()
    if suffix in {".xlsx", ".xlsm"}:
        return pd.read_excel(source)
    if suffix == ".csv":
        return pd.read_csv(source)
    return pd.read_csv(source, sep="\t")


def _prepare_ranked_enrichment(config: dict, enrichment_result: pd.DataFrame) -> dict | None:
    """Reconstruct the ranked list and gene sets used by fgsea for diagnostic plots.

    The statistical test itself remains the existing R/fgsea implementation.  This
    helper only recreates the deterministic running-score trace from the exact
    ranking and mapping so the workbook/HTML output can show how each ES was formed.
    """
    if not {"NES", "enrichmentScore"}.issubset(enrichment_result.columns):
        return None
    result_file = Path(str(config.get("result_file", "")))
    mapping_file = Path(str(config.get("mapping_file", "")))
    if not result_file.is_file() or not mapping_file.is_file():
        return None

    result_df = _read_flexible_table(result_file)
    if result_df.empty:
        return None
    configured_gene = str(config.get("result_gene_column", "") or "").strip()
    gene_col = configured_gene if configured_gene in result_df.columns else first_existing(
        result_df, ["gene_id", "gene", "Gene", "GeneID", "id", "ID"]
    )
    if not gene_col:
        gene_col = str(result_df.columns[0])
    configured_rank = str(config.get("rank_column", "") or "").strip()
    rank_col = configured_rank if configured_rank in result_df.columns else first_existing(
        result_df, ["stat", "WaldStatistic", "t", "log2FoldChange", "logFC", "log2fc"]
    )
    if not rank_col:
        return None

    rank_frame = pd.DataFrame(
        {
            "gene_id": result_df[gene_col].astype(str).str.strip(),
            "ranking_metric": pd.to_numeric(result_df[rank_col], errors="coerce"),
        }
    )
    rank_frame = rank_frame.loc[rank_frame["gene_id"].ne("") & rank_frame["ranking_metric"].notna()].copy()
    if rank_frame.empty:
        return None
    rank_frame["absolute_metric"] = rank_frame["ranking_metric"].abs()
    rank_frame = (
        rank_frame.sort_values("absolute_metric", ascending=False)
        .drop_duplicates("gene_id", keep="first")
        .drop(columns="absolute_metric")
    )

    if mapping_file.suffix.lower() == ".gmt":
        rows: list[dict[str, str]] = []
        with mapping_file.open("r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                pieces = raw.rstrip("\r\n").split("\t")
                if len(pieces) < 3:
                    continue
                term_id = pieces[0].strip()
                term_name = pieces[1].strip() or term_id
                for gene in pieces[2:]:
                    gene = gene.strip()
                    if gene:
                        rows.append({"gene_id": gene, "term_id": term_id, "term_name": term_name, "source": str(config.get("annotation_source", "Custom"))})
        mapping = pd.DataFrame(rows)
    else:
        raw = _read_flexible_table(mapping_file)
        if raw.shape[1] < 2:
            return None
        mg = str(config.get("mapping_gene_column", "") or "").strip()
        mt = str(config.get("mapping_term_column", "") or "").strip()
        mn = str(config.get("mapping_name_column", "") or "").strip()
        ms = str(config.get("mapping_source_column", "") or "").strip()
        mg = mg if mg in raw.columns else str(raw.columns[0])
        mt = mt if mt in raw.columns else str(raw.columns[1])
        mapping = pd.DataFrame(
            {
                "gene_id": raw[mg].astype(str).str.strip(),
                "term_id": raw[mt].astype(str).str.strip(),
                "term_name": raw[mn].astype(str).str.strip() if mn in raw.columns else raw[mt].astype(str).str.strip(),
                "source": raw[ms].astype(str).str.strip() if ms in raw.columns else str(config.get("annotation_source", "Custom")),
            }
        )
    if mapping.empty:
        return None
    mapping = mapping.loc[mapping["gene_id"].ne("") & mapping["term_id"].ne("")].drop_duplicates().copy()
    mapping["term_name"] = mapping["term_name"].where(mapping["term_name"].ne(""), mapping["term_id"])
    requested_source = str(config.get("annotation_source", "Custom") or "Custom").strip()
    if requested_source.casefold() != "custom" and "source" in mapping.columns and mapping["source"].astype(str).str.strip().ne("").any():
        subset = mapping.loc[mapping["source"].astype(str).str.strip().str.casefold().eq(requested_source.casefold())].copy()
        if not subset.empty:
            mapping = subset

    universe = set(rank_frame["gene_id"])
    universe_file = Path(str(config.get("universe_file", "") or ""))
    if universe_file.is_file():
        u = _read_flexible_table(universe_file)
        if not u.empty:
            universe &= set(u.iloc[:, 0].astype(str).str.strip())
    universe &= set(mapping["gene_id"])
    if len(universe) < 2:
        return None
    rank_frame = rank_frame.loc[rank_frame["gene_id"].isin(universe)].sort_values("ranking_metric", ascending=False).reset_index(drop=True)
    if rank_frame.empty:
        return None

    minimum = max(1, int(config.get("min_gene_set_size", 3)))
    maximum = max(minimum, int(config.get("max_gene_set_size", 500)))
    grouped = mapping.groupby("term_id", sort=False)
    pathways: dict[str, set[str]] = {}
    names: dict[str, str] = {}
    for term, frame in grouped:
        genes = set(frame["gene_id"]) & universe
        if minimum <= len(genes) <= maximum:
            pathways[str(term)] = genes
            label = next((str(v).strip() for v in frame["term_name"] if str(v).strip()), str(term))
            names[str(term)] = label
    if not pathways:
        return None

    ordered_result = enrichment_result.copy()
    ordered_result["_padj"] = pd.to_numeric(ordered_result.get("p.adjust"), errors="coerce")
    ordered_result["_abs_nes"] = pd.to_numeric(ordered_result.get("NES"), errors="coerce").abs()
    ordered_result = ordered_result.sort_values(["_padj", "_abs_nes"], ascending=[True, False], na_position="last")
    term_id_col = first_existing(ordered_result, ["ID", "term_id", "pathway", "pathway_id"])
    if not term_id_col:
        return None
    top_limit = max(1, min(20, int(config.get("gsea_profile_terms", 10))))
    terms: list[dict] = []
    seen: set[str] = set()
    metrics = rank_frame["ranking_metric"].to_numpy(dtype=float)
    genes = rank_frame["gene_id"].astype(str).to_numpy()
    n = len(rank_frame)
    for _, row in ordered_result.iterrows():
        term_id = str(row.get(term_id_col, "")).strip()
        if not term_id or term_id in seen or term_id not in pathways:
            continue
        hit_mask = np.isin(genes, list(pathways[term_id]))
        hit_count = int(hit_mask.sum())
        if hit_count <= 0 or hit_count >= n:
            continue
        weights = np.abs(metrics)
        hit_weights = weights * hit_mask
        norm_hit = float(hit_weights.sum())
        if not np.isfinite(norm_hit) or norm_hit <= 0:
            hit_increment = hit_mask.astype(float) / hit_count
        else:
            hit_increment = hit_weights / norm_hit
        miss_increment = (~hit_mask).astype(float) / max(1, n - hit_count)
        running = np.cumsum(hit_increment - miss_increment)
        reported_es = pd.to_numeric(pd.Series([row.get("enrichmentScore")]), errors="coerce").iloc[0]
        if np.isfinite(reported_es) and reported_es < 0:
            peak_index = int(np.argmin(running))
        elif np.isfinite(reported_es) and reported_es > 0:
            peak_index = int(np.argmax(running))
        else:
            peak_index = int(np.argmax(np.abs(running)))
        terms.append(
            {
                "term_id": term_id,
                "description": str(row.get("Description") or names.get(term_id) or term_id),
                "source": str(row.get("source") or requested_source),
                "ES": float(reported_es) if np.isfinite(reported_es) else float(running[peak_index]),
                "NES": float(pd.to_numeric(pd.Series([row.get("NES")]), errors="coerce").iloc[0]),
                "pvalue": float(pd.to_numeric(pd.Series([row.get("pvalue")]), errors="coerce").iloc[0]),
                "padj": float(pd.to_numeric(pd.Series([row.get("p.adjust")]), errors="coerce").iloc[0]),
                "running": running,
                "hit_mask": hit_mask,
                "peak_index": peak_index,
            }
        )
        seen.add(term_id)
        if len(terms) >= top_limit:
            break
    if not terms:
        return None
    return {"rank_frame": rank_frame, "terms": terms, "mapping": mapping}


def _write_ranked_enrichment_tables(prepared: dict, enrichment_result: pd.DataFrame, output_dir: Path) -> None:
    rank_frame = prepared["rank_frame"].copy()
    rank_frame.insert(0, "rank", np.arange(1, len(rank_frame) + 1))
    rank_frame.to_csv(output_dir / "gsea_ranked_metric.tsv", sep="\t", index=False)

    profile_rows: list[dict] = []
    n = len(rank_frame)
    max_points = 5000
    genes = rank_frame["gene_id"].astype(str).to_numpy()
    metrics = rank_frame["ranking_metric"].to_numpy(dtype=float)
    for term in prepared["terms"]:
        running = term["running"]
        hits = np.flatnonzero(term["hit_mask"])
        base = np.linspace(0, n - 1, min(n, max_points), dtype=int)
        keep = np.unique(np.concatenate([base, hits, np.array([term["peak_index"]], dtype=int)]))
        for index in keep:
            profile_rows.append(
                {
                    "term_id": term["term_id"],
                    "description": term["description"],
                    "source": term["source"],
                    "rank": int(index + 1),
                    "gene_id": genes[index],
                    "ranking_metric": float(metrics[index]),
                    "running_enrichment_score": float(running[index]),
                    "is_gene_set_hit": int(term["hit_mask"][index]),
                    "is_es_extremum": int(index == term["peak_index"]),
                    "ES": term["ES"],
                    "NES": term["NES"],
                    "pvalue": term["pvalue"],
                    "p.adjust": term["padj"],
                }
            )
    pd.DataFrame(profile_rows).to_csv(output_dir / "gsea_running_score_profiles.tsv", sep="\t", index=False)

    leading_col = first_existing(enrichment_result, ["leadingEdge", "leading_edge", "core_enrichment"])
    term_col = first_existing(enrichment_result, ["ID", "term_id", "pathway", "pathway_id"])
    if leading_col and term_col:
        leading_rows: list[dict] = []
        for _, row in enrichment_result.iterrows():
            genes_list = _split_gene_values(row.get(leading_col))
            for order, gene in enumerate(genes_list, start=1):
                leading_rows.append(
                    {
                        "term_id": str(row.get(term_col, "")),
                        "description": str(row.get("Description", row.get(term_col, ""))),
                        "gene_id": gene,
                        "leading_edge_order": order,
                        "NES": row.get("NES", ""),
                        "p.adjust": row.get("p.adjust", ""),
                    }
                )
        if leading_rows:
            pd.DataFrame(leading_rows).to_csv(output_dir / "leading_edge_genes.tsv", sep="\t", index=False)


def _rank_metric_traces(rank_frame: pd.DataFrame) -> list[go.Scattergl]:
    x = np.arange(1, len(rank_frame) + 1)
    y = rank_frame["ranking_metric"].to_numpy(dtype=float)
    positive = np.where(y >= 0, y, np.nan)
    negative = np.where(y < 0, y, np.nan)
    return [
        go.Scattergl(x=x, y=positive, mode="lines", fill="tozeroy", line={"width": 1, "color": "#bb1f2f"}, fillcolor="rgba(187,31,47,0.72)", name="Positive ranked metric", hovertemplate="Rank %{x}<br>Metric %{y:.4g}<extra></extra>"),
        go.Scattergl(x=x, y=negative, mode="lines", fill="tozeroy", line={"width": 1, "color": "#2f66ad"}, fillcolor="rgba(47,102,173,0.72)", name="Negative ranked metric", hovertemplate="Rank %{x}<br>Metric %{y:.4g}<extra></extra>"),
    ]


def gsea_supplemental_plots(config: dict, enrichment_result: pd.DataFrame, output_dir: Path) -> list[str]:
    prepared = _prepare_ranked_enrichment(config, enrichment_result)
    if prepared is None:
        return []
    _write_ranked_enrichment_tables(prepared, enrichment_result, output_dir)
    rank_frame = prepared["rank_frame"]
    terms = prepared["terms"]
    created: list[str] = []
    ranks = np.arange(1, len(rank_frame) + 1)

    # One publication-style three-panel GSEA view with a term selector.
    fig = make_subplots(rows=3, cols=1, shared_xaxes=True, vertical_spacing=0.035, row_heights=[0.43, 0.14, 0.43])
    for trace in _rank_metric_traces(rank_frame):
        fig.add_trace(trace, row=3, col=1)
    term_trace_indices: list[tuple[int, int]] = []
    for index, term in enumerate(terms):
        visible = index == 0
        hit_ranks = ranks[term["hit_mask"]]
        line_trace = go.Scattergl(
            x=ranks,
            y=term["running"],
            mode="lines",
            visible=visible,
            name=term["description"],
            line={"width": 2},
            hovertemplate="Rank %{x}<br>Running ES %{y:.4g}<extra></extra>",
        )
        hit_trace = go.Scattergl(
            x=hit_ranks,
            y=np.ones(len(hit_ranks)),
            mode="markers",
            visible=visible,
            marker={"symbol": "line-ns-open", "size": 13, "line": {"width": 1.1}},
            name="Gene-set hits",
            hovertemplate="Hit at rank %{x}<extra></extra>",
        )
        fig.add_trace(line_trace, row=1, col=1)
        line_index = len(fig.data) - 1
        fig.add_trace(hit_trace, row=2, col=1)
        hit_index = len(fig.data) - 1
        term_trace_indices.append((line_index, hit_index))
    buttons = []
    for selected_index, term in enumerate(terms):
        visibility = [True, True] + [False] * (2 * len(terms))
        line_index, hit_index = term_trace_indices[selected_index]
        visibility[line_index] = True
        visibility[hit_index] = True
        title = f"{term['description']} ({term['term_id']}) · NES {term['NES']:.3g} · p {term['pvalue']:.3g} · adjusted p {term['padj']:.3g}"
        buttons.append({"label": f"{term['term_id']} · {term['description'][:55]}", "method": "update", "args": [{"visible": visibility}, {"title": {"text": title, "x": 0.5}}]})
    first = terms[0]
    fig.update_layout(
        title={"text": f"{first['description']} ({first['term_id']}) · NES {first['NES']:.3g} · p {first['pvalue']:.3g} · adjusted p {first['padj']:.3g}", "x": 0.5},
        updatemenus=[{"buttons": buttons, "direction": "down", "x": 0.01, "y": 1.14, "xanchor": "left", "yanchor": "top"}],
        showlegend=False,
        height=860,
    )
    fig.update_yaxes(title_text="Enrichment score (ES)", row=1, col=1, zeroline=True, zerolinecolor="#555")
    fig.update_yaxes(title_text="Gene-set hits", row=2, col=1, showticklabels=False, range=[0, 2])
    fig.update_yaxes(title_text="Ranked list metric", row=3, col=1, zeroline=True, zerolinecolor="#555")
    fig.update_xaxes(title_text="Rank in ordered dataset", row=3, col=1)
    write_plot(fig, output_dir / "gsea_term_profiles_interactive.html")
    created.append("gsea_term_profiles_interactive.html")

    # Overlay the strongest few terms, mirroring the multi-term running-score view.
    overlay_terms = terms[: min(5, len(terms))]
    multi = make_subplots(rows=3, cols=1, shared_xaxes=True, vertical_spacing=0.035, row_heights=[0.43, 0.18, 0.39])
    for term in overlay_terms:
        multi.add_trace(go.Scattergl(x=ranks, y=term["running"], mode="lines", name=f"{term['term_id']} · {term['description'][:42]}", hovertemplate="Rank %{x}<br>Running ES %{y:.4g}<extra></extra>"), row=1, col=1)
    for lane, term in enumerate(overlay_terms, start=1):
        hit_ranks = ranks[term["hit_mask"]]
        multi.add_trace(go.Scattergl(x=hit_ranks, y=np.full(len(hit_ranks), lane), mode="markers", marker={"symbol": "line-ns-open", "size": 10}, name=term["term_id"], showlegend=False, hovertemplate=f"{term['term_id']}<br>Rank %{{x}}<extra></extra>"), row=2, col=1)
    for trace in _rank_metric_traces(rank_frame):
        multi.add_trace(trace, row=3, col=1)
    multi.update_layout(title={"text": "Top ranked gene sets · running enrichment score", "x": 0.5}, height=850, legend={"orientation": "h", "y": 1.08})
    multi.update_yaxes(title_text="Enrichment score (ES)", row=1, col=1, zeroline=True)
    multi.update_yaxes(title_text="Gene-set hits", row=2, col=1, tickmode="array", tickvals=list(range(1, len(overlay_terms) + 1)), ticktext=[term["term_id"] for term in overlay_terms])
    multi.update_yaxes(title_text="Ranked list metric", row=3, col=1, zeroline=True)
    multi.update_xaxes(title_text="Rank in ordered dataset", row=3, col=1)
    write_plot(multi, output_dir / "gsea_multi_term_running_score_interactive.html")
    created.append("gsea_multi_term_running_score_interactive.html")

    es = pd.to_numeric(enrichment_result["enrichmentScore"], errors="coerce").dropna().to_numpy(dtype=float)
    if len(es):
        bins = min(40, max(8, int(round(math.sqrt(len(es))))))
        counts, edges = np.histogram(es, bins=bins)
        centers = (edges[:-1] + edges[1:]) / 2
        global_es = go.Figure(go.Scatter(x=centers, y=counts, mode="lines+markers", line={"width": 2}, hovertemplate="ES %{x:.4g}<br>Gene sets %{y}<extra></extra>"))
        global_es.update_layout(title={"text": "Global enrichment-score distribution", "x": 0.5}, xaxis_title="Enrichment score (ES)", yaxis_title="# of gene sets")
        write_plot(global_es, output_dir / "gsea_global_es_interactive.html")
        created.append("gsea_global_es_interactive.html")

    nes = pd.to_numeric(enrichment_result["NES"], errors="coerce")
    pvalue = pd.to_numeric(enrichment_result.get("pvalue"), errors="coerce")
    qvalue_col = first_existing(enrichment_result, ["qvalue", "p.adjust", "padj", "FDR"])
    qvalue = pd.to_numeric(enrichment_result[qvalue_col], errors="coerce") if qvalue_col else pd.Series(np.nan, index=enrichment_result.index)
    valid = nes.notna()
    if valid.any():
        significance = go.Figure()
        significance.add_trace(go.Scatter(x=nes[valid], y=pvalue[valid], mode="markers", marker={"size": 7, "color": "#111"}, name="Nominal P-value", hovertemplate="NES %{x:.4g}<br>Nominal p %{y:.4g}<extra></extra>"))
        significance.add_trace(go.Scatter(x=nes[valid], y=qvalue[valid], mode="markers", marker={"size": 7, "symbol": "square", "color": "#e31a1c"}, name="FDR q-value", yaxis="y2", hovertemplate="NES %{x:.4g}<br>FDR q %{y:.4g}<extra></extra>"))
        significance.update_layout(title={"text": "NES vs significance", "x": 0.5}, xaxis_title="NES", yaxis={"title": "Nominal P-value", "range": [0, 1.05]}, yaxis2={"title": "FDR q-value", "overlaying": "y", "side": "right", "range": [0, 1.05]}, legend={"orientation": "h", "y": -0.16})
        write_plot(significance, output_dir / "gsea_nes_significance_interactive.html")
        created.append("gsea_nes_significance_interactive.html")
    return created


def _preferred_group_column(metadata: pd.DataFrame) -> str | None:
    lookup = {str(column).casefold(): str(column) for column in metadata.columns}
    for name in ("condition", "group", "treatment", "phenotype", "class"):
        if name in lookup:
            return lookup[name]
    return None


def network_module_expression_plots(config: dict, output_dir: Path) -> list[str]:
    """Add expression-pattern heatmap/trend summaries without altering network inference."""
    expression_path = output_dir / "network_expression_used.tsv"
    assignment_path = output_dir / "module_assignments.tsv"
    metadata_path = output_dir / "network_metadata_used.tsv"
    if not expression_path.is_file() or not assignment_path.is_file():
        return []
    expression = read_table(str(expression_path))
    assignments = read_table(str(assignment_path))
    if expression.empty or assignments.empty or "gene_id" not in expression.columns or not {"gene_id", "module"}.issubset(assignments.columns):
        return []
    assignments = assignments[["gene_id", "module"]].drop_duplicates("gene_id")
    merged = expression.merge(assignments, on="gene_id", how="inner")
    sample_cols = [column for column in expression.columns if column != "gene_id" and column in merged.columns]
    if len(sample_cols) < 2 or merged.empty:
        return []
    numeric = merged[sample_cols].apply(pd.to_numeric, errors="coerce")
    keep = numeric.notna().all(axis=1)
    merged = merged.loc[keep].reset_index(drop=True)
    numeric = numeric.loc[keep].reset_index(drop=True)
    if merged.empty:
        return []

    # GENIE3's Regulator/Target labels are node roles, not co-expression modules.
    module_values = merged["module"].astype(str)
    meaningful = [m for m in module_values.unique() if m not in {"Not.Correlated", "Predicted regulation", "Regulator", "Target"}]
    if not meaningful:
        return []
    module_mask = module_values.isin(meaningful)
    merged = merged.loc[module_mask].reset_index(drop=True)
    numeric = numeric.loc[module_mask].reset_index(drop=True)
    if merged.empty:
        return []

    means = numeric.mean(axis=1)
    stds = numeric.std(axis=1, ddof=0).replace(0, np.nan)
    z = numeric.sub(means, axis=0).div(stds, axis=0).replace([np.inf, -np.inf], np.nan).fillna(0.0)

    metadata = read_table(str(metadata_path)) if metadata_path.is_file() else pd.DataFrame({"sample_id": sample_cols})
    sample_id_col = first_existing(metadata, ["sample_id", "sample", "Sample"]) or (str(metadata.columns[0]) if not metadata.empty else "sample_id")
    metadata[sample_id_col] = metadata[sample_id_col].astype(str)
    metadata = metadata.loc[metadata[sample_id_col].isin(sample_cols)].copy()
    group_col = _preferred_group_column(metadata)
    if group_col:
        group_order = {value: index for index, value in enumerate(pd.unique(metadata[group_col].astype(str)))}
        metadata["_group_order"] = metadata[group_col].astype(str).map(group_order)
        metadata["_sample_order"] = metadata[sample_id_col].map({sample: index for index, sample in enumerate(sample_cols)})
        metadata = metadata.sort_values(["_group_order", "_sample_order"])
        ordered_samples = [sample for sample in metadata[sample_id_col].astype(str) if sample in sample_cols]
        ordered_samples += [sample for sample in sample_cols if sample not in ordered_samples]
    else:
        ordered_samples = sample_cols
    z = z[ordered_samples]

    module_counts = merged["module"].astype(str).value_counts()
    def module_key(value: str) -> list[object]:
        return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", str(value))]
    module_order = sorted(module_counts.index, key=module_key)
    # Sort genes inside each module by agreement with that module's mean profile.
    ordered_indices: list[int] = []
    for module in module_order:
        idx = merged.index[merged["module"].astype(str).eq(module)].to_numpy()
        block = z.loc[idx].to_numpy(dtype=float)
        centroid = block.mean(axis=0)
        centroid_norm = np.linalg.norm(centroid)
        if centroid_norm > 0:
            row_norm = np.linalg.norm(block, axis=1)
            score = np.divide(block @ centroid, row_norm * centroid_norm, out=np.zeros(len(idx)), where=(row_norm * centroid_norm) > 0)
            idx = idx[np.argsort(-score)]
        ordered_indices.extend(idx.tolist())

    display_limit = max(100, min(5000, int(config.get("module_heatmap_gene_limit", 2000))))
    if len(ordered_indices) > display_limit:
        selected_indices: list[int] = []
        total = sum(int(module_counts[m]) for m in module_order)
        for module in module_order:
            module_idx = [i for i in ordered_indices if str(merged.loc[i, "module"]) == module]
            quota = max(5, int(round(display_limit * len(module_idx) / max(1, total))))
            selected_indices.extend(module_idx[:quota])
        ordered_indices = selected_indices[:display_limit]
    display = merged.loc[ordered_indices, ["gene_id", "module"]].reset_index(drop=True)
    display_z = z.loc[ordered_indices, ordered_samples].reset_index(drop=True)

    z_table = pd.concat([display, display_z], axis=1)
    z_table.to_csv(output_dir / "module_expression_zscores.tsv", sep="\t", index=False)

    trend_rows: list[dict] = []
    metadata_lookup = metadata.set_index(sample_id_col) if not metadata.empty else pd.DataFrame()
    for module in module_order:
        idx = merged.index[merged["module"].astype(str).eq(module)]
        if not len(idx):
            continue
        block = z.loc[idx, ordered_samples]
        for sample in ordered_samples:
            row = {
                "module": module,
                "gene_count": int(len(idx)),
                "sample_id": sample,
                "mean_zscore": float(block[sample].mean()),
                "median_zscore": float(block[sample].median()),
            }
            if group_col and sample in metadata_lookup.index:
                value = metadata_lookup.loc[sample, group_col]
                if isinstance(value, pd.Series):
                    value = value.iloc[0]
                row["group"] = str(value)
            trend_rows.append(row)
    trends = pd.DataFrame(trend_rows)
    trends.to_csv(output_dir / "module_expression_trends.tsv", sep="\t", index=False)

    # Heatmap with module labels and top functional-enrichment terms aligned to each module.
    centers: dict[str, float] = {}
    boundaries: list[float] = []
    cursor = 0
    for module in module_order:
        count = int((display["module"].astype(str) == module).sum())
        if count <= 0:
            continue
        centers[module] = cursor + (count - 1) / 2
        cursor += count
        boundaries.append(cursor - 0.5)
    custom = np.empty((len(display), len(ordered_samples), 2), dtype=object)
    custom[:, :, 0] = np.repeat(display["gene_id"].astype(str).to_numpy()[:, None], len(ordered_samples), axis=1)
    custom[:, :, 1] = np.repeat(display["module"].astype(str).to_numpy()[:, None], len(ordered_samples), axis=1)
    heat = make_subplots(rows=1, cols=2, column_widths=[0.72, 0.28], horizontal_spacing=0.045)
    heat.add_trace(go.Heatmap(z=display_z.to_numpy(dtype=float), x=ordered_samples, y=np.arange(len(display)), customdata=custom, zmid=0, zmin=-4, zmax=4, colorscale="RdBu_r", colorbar={"title": {"text": "Z score", "side": "right"}, "x": 1.025, "xanchor": "left", "y": 0.50, "yanchor": "middle", "len": 0.72, "thickness": 16}, hovertemplate="<b>%{customdata[0]}</b><br>%{customdata[1]}<br>Sample %{x}<br>Z score %{z:.3f}<extra></extra>"), row=1, col=1)
    enrichment_path = output_dir / "network_module_go_enrichment.tsv"
    enrich = read_table(str(enrichment_path)) if enrichment_path.is_file() else pd.DataFrame()
    for module, center in centers.items():
        text = f"<b>{module}</b><br>{int(module_counts.get(module, 0))} genes"
        if not enrich.empty and "module" in enrich.columns:
            block = enrich.loc[enrich["module"].astype(str).eq(module)].copy()
            if "padj" in block.columns:
                block["_padj"] = pd.to_numeric(block["padj"], errors="coerce")
                block = block.sort_values(["_padj", "pvalue"] if "pvalue" in block.columns else ["_padj"]).head(3)
            else:
                block = block.head(3)
            terms = [str(value) for value in block.get("term_name", block.get("term_id", pd.Series(dtype=str))).tolist() if str(value).strip()]
            if terms:
                text += "<br>" + "<br>".join(terms)
        heat.add_trace(go.Scatter(x=[0.02], y=[center], mode="text", text=[text], textposition="middle right", hoverinfo="skip", showlegend=False, meta={"bra_module_raw": str(module)}), row=1, col=2)
    for boundary in boundaries[:-1]:
        heat.add_hline(y=boundary, line_width=1, line_color="#d0d7d2", row=1, col=1)
    heat.update_yaxes(tickmode="array", tickvals=list(centers.values()), ticktext=list(centers.keys()), autorange="reversed", title_text="Gene modules", showgrid=False, zeroline=False, row=1, col=1)
    heat.update_yaxes(range=[len(display) - 0.5, -0.5], showticklabels=False, showgrid=False, zeroline=False, row=1, col=2)
    heat.update_xaxes(title_text="Samples", tickangle=-60, showgrid=False, zeroline=False, row=1, col=1)
    heat.update_xaxes(visible=False, range=[0, 1], showgrid=False, zeroline=False, row=1, col=2)
    heat.update_layout(title={"text": "Module expression heatmap with functional enrichment", "x": 0.5}, meta={"bra_module_axes": [{"axis": "yaxis", "values": list(centers.keys()), "tickvals": list(centers.values())}]}, height=min(1700, max(720, 430 + 45 * len(centers))), showlegend=False, margin={"l": 105, "r": 155, "t": 58, "b": 105})
    if group_col and not metadata.empty:
        ordered_meta = metadata.set_index(sample_id_col)
        groups: list[tuple[str, int, int]] = []
        start = 0
        current = None
        for i, sample in enumerate(ordered_samples):
            value_obj: object = ""
            if sample in ordered_meta.index:
                value_obj = ordered_meta.loc[sample, group_col]
                if isinstance(value_obj, pd.Series):
                    value_obj = value_obj.iloc[0]
            value = str(value_obj)
            if current is None:
                current, start = value, i
            elif value != current:
                groups.append((current, start, i - 1)); current, start = value, i
        if current is not None:
            groups.append((current, start, len(ordered_samples) - 1))
        for label, lo, hi in groups:
            heat.add_annotation(x=ordered_samples[(lo + hi) // 2], y=1.06, xref="x", yref="paper", text=label, showarrow=False, font={"size": 12})
    write_plot(heat, output_dir / "module_expression_heatmap_interactive.html")

    # Per-module trend panels across the ordered samples, analogous to vendor trend plots.
    trend_modules = list(module_counts.loc[module_order].sort_values(ascending=False).head(12).index)
    trend_fig = make_subplots(rows=len(trend_modules), cols=1, shared_xaxes=True, vertical_spacing=min(0.03, 0.16 / max(1, len(trend_modules))), subplot_titles=[f"{module} · Gene size: {int(module_counts[module])}" for module in trend_modules])
    for row_index, module in enumerate(trend_modules, start=1):
        block = trends.loc[trends["module"].astype(str).eq(module)].set_index("sample_id").reindex(ordered_samples)
        trend_fig.add_trace(go.Scatter(x=ordered_samples, y=block["mean_zscore"], mode="lines+markers", line={"width": 2}, marker={"size": 5}, name=module, showlegend=False, customdata=block[["gene_count"]].to_numpy(), hovertemplate="Sample %{x}<br>Mean Z %{y:.3f}<br>Genes %{customdata[0]}<extra></extra>", meta={"bra_module_raw": str(module)}), row=row_index, col=1)
        trend_fig.update_yaxes(title_text="Mean Z", showgrid=False, zeroline=True, zerolinecolor="#aeb8b1", zerolinewidth=1.1, row=row_index, col=1)
        trend_fig.update_xaxes(showgrid=False, zeroline=False, row=row_index, col=1)
    trend_fig.update_xaxes(title_text="Samples", tickangle=-60, showgrid=False, row=len(trend_modules), col=1)
    for annotation, module in zip(trend_fig.layout.annotations, trend_modules):
        annotation.name = f"BRA_MODULE::{module}"
    trend_fig.update_layout(title={"text": "Module expression trends", "x": 0.5}, height=max(620, 150 * len(trend_modules)))
    write_plot(trend_fig, output_dir / "module_expression_trends_interactive.html")
    return ["module_expression_heatmap_interactive.html", "module_expression_trends_interactive.html"]


GO_ROOTS = {"BP": "GO:0008150", "MF": "GO:0003674", "CC": "GO:0005575"}
GO_BRANCH_NAMES = {"BP": "Biological Process", "MF": "Molecular Function", "CC": "Cellular Component"}
GO_BRANCH_COLORS = {"BP": "#f8766d", "MF": "#619cff", "CC": "#00ba38"}


def _go_support_tables(output_dir: Path) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    node_path = output_dir / "go_ontology_nodes.tsv"
    edge_path = output_dir / "go_ontology_edges.tsv"
    mapping_path = output_dir / "annotation_mapping_used.tsv"
    if not node_path.is_file() or not edge_path.is_file() or not mapping_path.is_file():
        return pd.DataFrame(), pd.DataFrame(), pd.DataFrame()
    nodes = read_table(str(node_path))
    edges = read_table(str(edge_path))
    mapping = read_table(str(mapping_path))
    if "GO_ID" not in nodes.columns or not {"parent_id", "child_id"}.issubset(edges.columns):
        return pd.DataFrame(), pd.DataFrame(), pd.DataFrame()
    nodes["GO_ID"] = nodes["GO_ID"].astype(str)
    nodes["term"] = nodes.get("term", nodes["GO_ID"]).fillna(nodes["GO_ID"]).astype(str)
    nodes["ontology"] = nodes.get("ontology", "").fillna("").astype(str).str.upper()
    edges["parent_id"] = edges["parent_id"].astype(str)
    edges["child_id"] = edges["child_id"].astype(str)
    if "ontology" in edges.columns:
        edges["ontology"] = edges["ontology"].fillna("").astype(str).str.upper()
    mapping["gene_id"] = mapping["gene_id"].astype(str)
    mapping["term_id"] = mapping["term_id"].astype(str)
    universe_path = output_dir / "gene_universe_used.tsv"
    if universe_path.is_file():
        try:
            universe = read_table(str(universe_path))
            if not universe.empty:
                universe_genes = set(universe.iloc[:, 0].astype(str).str.strip())
                mapping = mapping.loc[mapping["gene_id"].isin(universe_genes)].copy()
        except Exception:
            pass
    return nodes, edges, mapping


def _go_graphs(nodes: pd.DataFrame, edges: pd.DataFrame) -> dict[str, nx.DiGraph]:
    graphs: dict[str, nx.DiGraph] = {}
    node_branch = dict(zip(nodes["GO_ID"].astype(str), nodes["ontology"].astype(str))) if not nodes.empty else {}
    for branch in ("BP", "MF", "CC"):
        graph = nx.DiGraph()
        branch_nodes = nodes.loc[nodes["ontology"].eq(branch), "GO_ID"].astype(str).tolist() if not nodes.empty else []
        graph.add_nodes_from(branch_nodes)
        for _, row in edges.iterrows():
            parent = str(row.get("parent_id", ""))
            child = str(row.get("child_id", ""))
            edge_branch = str(row.get("ontology", "") or node_branch.get(child, "")).upper()
            if edge_branch == branch and parent and child:
                graph.add_edge(parent, child, relationship=str(row.get("relationship", "parent")))
        root = GO_ROOTS[branch]
        if root in node_branch or graph.number_of_nodes():
            graph.add_node(root)
        graphs[branch] = graph
    return graphs


def _go_levels(graph: nx.DiGraph, root: str) -> dict[str, int]:
    if graph.number_of_nodes() == 0:
        return {}
    levels: dict[str, int] = {}
    try:
        order = list(nx.topological_sort(graph))
    except nx.NetworkXUnfeasible:
        order = list(graph.nodes())
    for node in order:
        preds = [p for p in graph.predecessors(node) if p in levels]
        if node == root:
            levels[node] = 0
        elif preds:
            levels[node] = max(levels[p] + 1 for p in preds)
        else:
            levels[node] = 0
    if root in graph:
        try:
            reachable = nx.descendants(graph, root) | {root}
            # A subgraph exported from GO.db should be rooted. Keep unreachable obsolete
            # terms, if any, at their local level rather than failing the plot.
            for node in reachable:
                if node not in levels:
                    levels[node] = 0
        except Exception:
            pass
    return levels


def _go_ancestor_sets(graph: nx.DiGraph, terms: Iterable[str]) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for term in terms:
        term = str(term)
        if term in graph:
            result[term] = set(nx.ancestors(graph, term)) | {term}
        else:
            result[term] = {term}
    return result


def _discover_gene_lengths(config: dict) -> pd.DataFrame:
    """Recover bacterial gene lengths from the RNA-processing handoff.

    RNA Processing already exports ``gene_lengths.tsv`` and ``features.saf``.
    Prefer those exact sources, then fall back to coordinate tables or a GFF/GTF
    referenced by downstream configuration.  This avoids reporting gene length as
    unavailable simply because the GO result folder is a sibling of RNA Processing.
    """
    candidates: list[Path] = []
    seen: set[str] = set()

    def add(raw: object) -> None:
        value = str(raw or "").strip().strip('"')
        if not value:
            return
        path = Path(value)
        if path.exists():
            key = str(path.resolve())
            if key not in seen:
                seen.add(key); candidates.append(path.resolve())

    for key in ("gene_length_file", "gene_lengths_file", "coordinate_file", "gene_metadata_file", "annotation_file", "gene_annotation_file"):
        add(config.get(key))
    reference = config.get("reference")
    if isinstance(reference, dict):
        add(reference.get("annotation"))

    result_raw = str(config.get("result_file", "") or "").strip()
    result_path = Path(result_raw) if result_raw else None
    seeds = []
    if result_path is not None:
        seeds.append(result_path.parent)
    for key in ("mapping_file", "annotation_table_file", "annotation_sequence_file"):
        raw = str(config.get(key, "") or "").strip()
        if raw:
            path = Path(raw)
            seeds.append(path if path.is_dir() else path.parent)

    relatives = (
        "gene_lengths.tsv", "gene lengths.tsv",
        "reference/gene_lengths.tsv", "Reference support/gene_lengths.tsv",
        "analysis_ready/reference/gene_lengths.tsv", "Intermediate files/Reference/gene_lengths.tsv",
        "features.saf", "reference/features.saf", "Reference support/features.saf",
        "analysis_ready/reference/features.saf", "Intermediate files/Reference/features.saf",
        "gene_coordinates.tsv", "gene coordinates.tsv", "Reference support/gene coordinates.tsv",
        "Reference support/gene_coordinates.tsv", "reference/gene_coordinates.tsv",
        "annotation.normalized.gff3", "reference/annotation.normalized.gff3",
        "analysis_ready/reference/annotation.normalized.gff3",
    )
    for seed in seeds:
        current = seed
        for _ in range(6):
            for rel in relatives:
                add(current / rel)
            if current.parent == current:
                break
            current = current.parent

    for candidate in candidates:
        if not candidate.is_file():
            continue
        lower = candidate.name.lower()
        try:
            if lower.endswith((".gff", ".gff3", ".gtf")):
                frame = pd.read_csv(candidate, sep="\t", comment="#", header=None, usecols=[2,3,4,8], names=["feature_type","start","end","attributes"], dtype={"attributes":str})
                frame = frame.loc[frame["feature_type"].astype(str).str.casefold().isin({"gene","cds"})].copy()
                if frame.empty:
                    continue
                def attr_id(raw: object) -> str:
                    value=str(raw or "")
                    for key in ("locus_tag", "gene_id", "ID", "gene", "Name", "Parent"):
                        m=re.search(rf'(?:^|;)\\s*{re.escape(key)}[=\\s]+[\"\']?([^;\"\']+)', value)
                        if m:
                            return re.sub(r'^(gene|cds|rna)-', '', m.group(1).strip(), flags=re.I)
                    return ""
                out=pd.DataFrame({"gene_id":frame["attributes"].map(attr_id),"length_bp":pd.to_numeric(frame["end"],errors="coerce")-pd.to_numeric(frame["start"],errors="coerce")+1})
            else:
                frame = read_table(str(candidate))
                gene_col = first_existing(frame, ["GeneID", "gene_id", "gene", "ID", "locus_tag", "original_id"])
                length_col = first_existing(frame, ["length_bp", "Length", "length", "gene_length", "geneLength"])
                if gene_col and length_col:
                    out = pd.DataFrame({"gene_id": frame[gene_col].astype(str).str.strip(), "length_bp": pd.to_numeric(frame[length_col], errors="coerce")})
                else:
                    start_col = first_existing(frame, ["Start", "start", "gene_start", "chromStart"])
                    end_col = first_existing(frame, ["End", "end", "gene_end", "chromEnd"])
                    if not gene_col or not start_col or not end_col:
                        continue
                    out = pd.DataFrame({"gene_id": frame[gene_col].astype(str).str.strip(), "length_bp": pd.to_numeric(frame[end_col], errors="coerce") - pd.to_numeric(frame[start_col], errors="coerce") + 1})
        except Exception:
            continue
        out = out.loc[out["gene_id"].ne("") & pd.to_numeric(out["length_bp"], errors="coerce").gt(0)].copy()
        if not out.empty:
            out["length_bp"] = pd.to_numeric(out["length_bp"], errors="coerce").round().astype(int)
            return out.drop_duplicates("gene_id", keep="first")
    return pd.DataFrame(columns=["gene_id", "length_bp"])


def _enrichment_richfactor_and_circos(config: dict, result: pd.DataFrame, output_dir: Path) -> list[str]:
    """Create linked RichFactor and enrichment Circos summaries for GO/KEGG/etc."""
    created: list[str] = []
    if result.empty:
        return created
    id_col = first_existing(result, ["ID", "term_id", "pathway_id", "pathway"])
    desc_col = first_existing(result, ["Description", "term_name", "pathway_name", "pathway"]) or id_col
    padj_col = first_existing(result, ["p.adjust", "p_adjust_BH", "padj", "FDR", "qvalue"])
    p_col = first_existing(result, ["pvalue", "PValue", "p.value"]) or padj_col
    rich_col = first_existing(result, ["RichFactor", "rich_factor", "GeneRatioNumeric"])
    count_col = first_existing(result, ["SignificantGenes", "Count", "setSize", "size"])
    size_col = first_existing(result, ["GeneSetSize", "Annotated", "setSize", "size"])
    genes_col = first_existing(result, ["geneID", "leadingEdge", "leading_edge", "core_enrichment"])
    if not id_col or not desc_col or not padj_col:
        return created
    frame = result.copy()
    frame[padj_col] = pd.to_numeric(frame[padj_col], errors="coerce")
    if p_col:
        frame[p_col] = pd.to_numeric(frame[p_col], errors="coerce")
    if rich_col:
        frame[rich_col] = pd.to_numeric(frame[rich_col], errors="coerce")
    elif count_col and size_col:
        num = pd.to_numeric(frame[count_col], errors="coerce")
        den = pd.to_numeric(frame[size_col], errors="coerce")
        frame["RichFactor"] = num / den.replace(0, np.nan)
        rich_col = "RichFactor"
    if not rich_col:
        return created
    frame["label"] = frame[desc_col].fillna(frame[id_col]).astype(str)
    frame["minus_log10_adjusted_p"] = safe_neg_log10(frame[padj_col])
    frame["plot_count"] = pd.to_numeric(frame[count_col], errors="coerce").fillna(1) if count_col else 1
    category_col = first_existing(frame, ["ontology", "Category", "category", "source"])
    frame["plot_category"] = frame[category_col].fillna("Other").astype(str) if category_col else str(config.get("annotation_source", "Enrichment"))
    frame["__bra_term"] = frame[id_col].astype(str)
    frame["__bra_label"] = frame["label"].astype(str)
    frame["__bra_genes"] = frame[genes_col].fillna("").astype(str) if genes_col else ""
    # More than about thirty named biological categories cannot be read in one
    # fixed-height panel.  Keep the strongest terms and grow the canvas by row.
    top_n = max(6, min(14, int(config.get("top_terms", 30))))
    top = frame.sort_values([padj_col, "minus_log10_adjusted_p"], ascending=[True, False], na_position="last").head(top_n).copy()
    if top.empty:
        return created
    rich_table = top[[id_col, desc_col, padj_col, rich_col, "plot_count", "plot_category"]].copy()
    rich_table.columns = ["term_id", "term_name", "adjusted_p", "rich_factor", "gene_count", "category"]
    if p_col and p_col != padj_col:
        rich_table["nominal_p"] = pd.to_numeric(top[p_col], errors="coerce").to_numpy()
    rich_table.to_csv(output_dir / "enrichment_rich_factor.tsv", sep="\t", index=False)

    # Keep ontology/source groups together (BP, CC, MF, KEGG, ...), following
    # the grouped-category convention used in bacterial functional summaries.
    ordered = top.sort_values(["plot_category", rich_col], kind="stable").copy()
    bubble = px.scatter(
        ordered, x=rich_col, y="label", size="plot_count",
        color="minus_log10_adjusted_p",
        custom_data=["__bra_term", "__bra_label", "__bra_genes", "plot_count", padj_col],
        labels={rich_col: "Rich factor", "label": "Term", "minus_log10_adjusted_p": "−log₁₀ adjusted p"},
        color_continuous_scale="Viridis",
    )
    bubble.for_each_trace(lambda tr: tr.update(customdata=[["BRA_SELECTION", *row] for row in tr.customdata] if tr.customdata is not None else tr.customdata, hovertemplate="<b>%{customdata[2]}</b><br>%{customdata[1]}<br>Rich factor %{x:.3f}<br>Adjusted p %{customdata[5]:.3g}<br>Genes %{customdata[4]}<br><extra></extra>"))
    tickvals = ordered["label"].astype(str).tolist()
    bubble.update_yaxes(
        tickmode="array",
        tickvals=tickvals,
        ticktext=[_wrap_full_plot_label(v, 36) for v in tickvals],
        categoryorder="array",
        categoryarray=tickvals,
        automargin=True,
        domain=[0.11, 0.995],
    )
    bubble.update_xaxes(title_text="Rich factor", title_standoff=12, automargin=True, showticklabels=True, domain=[0.0, 0.93])
    bubble.update_layout(
        title={"text":""},
        height=max(680, 41 * len(ordered) + 145),
        margin={"l":255,"r":155,"t":20,"b":58},
        coloraxis_colorbar={"title":{"text":"−log₁₀ adjusted p","side":"right"},"x":1.025,"xanchor":"left","y":.52,"yanchor":"middle","len":.74,"thickness":18},
    )
    write_plot(bubble, output_dir / "enrichment_rich_factor_interactive.html")
    created.append("enrichment_rich_factor_interactive.html")

    # Keep the perimeter sparse enough for full biological labels in a fitted
    # viewport. Additional terms remain in the linked table and bar/dot views.
    # Additional terms remain available in the linked enrichment table and the
    # bar/dot views instead of being rendered as overlapping Circos text.
    circ = top.sort_values(["plot_category", padj_col], kind="stable").head(min(8, len(top))).copy().reset_index(drop=True)
    n = len(circ)
    theta = np.linspace(0, 360, n, endpoint=False)
    width = max(4.0, 315.0 / max(1, n))
    rich = pd.to_numeric(circ[rich_col], errors="coerce").fillna(0).clip(lower=0)
    rich_scale = rich / max(float(rich.max()), 1e-12)
    up_col = first_existing(circ, ["UpregulatedGenes", "up_count", "Up"])
    down_col = first_existing(circ, ["DownregulatedGenes", "down_count", "Down"])
    up = pd.to_numeric(circ[up_col], errors="coerce").fillna(0) if up_col else pd.Series(0, index=circ.index)
    down = pd.to_numeric(circ[down_col], errors="coerce").fillna(0) if down_col else pd.Series(0, index=circ.index)
    count_cap = max(float(max(up.max(), down.max())), 1.0)
    sig = safe_neg_log10(circ[padj_col])
    labels = [_wrap_full_plot_label(value, 25) for value in circ["label"]]
    custom = [["BRA_SELECTION", str(row[id_col]), str(row["label"]), str(row.get("__bra_genes", "")), float(row[padj_col]) if pd.notna(row[padj_col]) else None, float(rich.iloc[i]), float(up.iloc[i]), float(down.iloc[i]), str(row["plot_category"])] for i, (_, row) in enumerate(circ.iterrows())]
    polar = go.Figure()
    polar.add_trace(go.Barpolar(theta=theta, r=0.28 + 0.55 * rich_scale, base=0.20, width=width, marker={"color": sig, "colorscale": "YlOrRd", "showscale": False, "line": {"color": "white", "width": 1}}, customdata=custom, hovertemplate="<b>%{customdata[2]}</b><br>%{customdata[1]}<br>Adjusted p %{customdata[4]:.3g}<br>Rich factor %{customdata[5]:.3f}<br>Up genes %{customdata[6]}<br>Down genes %{customdata[7]}<extra>Click to show member genes/proteins in the spreadsheet</extra>", name="Rich factor"))
    polar.add_trace(go.Barpolar(theta=theta, r=0.05 + 0.34 * (up / count_cap), base=1.03, width=width, marker={"color": "#f26b61", "line": {"color": "white", "width": 0.8}}, customdata=custom, hovertemplate="<b>%{customdata[2]}</b><br>Up-regulated genes %{customdata[6]}<extra>Click to show members</extra>", name="Up-regulated"))
    polar.add_trace(go.Barpolar(theta=theta, r=0.05 + 0.34 * (down / count_cap), base=1.43, width=width, marker={"color": "#2fb7b2", "line": {"color": "white", "width": 0.8}}, customdata=custom, hovertemplate="<b>%{customdata[2]}</b><br>Down-regulated genes %{customdata[7]}<extra>Click to show members</extra>", name="Down-regulated"))
    polar.add_trace(go.Scatterpolar(theta=theta, r=np.full(n, 2.12), mode="markers", marker={"size": 11, "color": sig, "colorscale": "Viridis", "showscale": True, "colorbar": {"title": {"text": "−log₁₀ adjusted p", "side": "right"}, "x": 1.035, "xanchor": "left", "y": 0.50, "yanchor": "middle", "len": 0.54, "thickness": 18}}, customdata=custom, hovertemplate="<b>%{customdata[2]}</b><br>Adjusted p %{customdata[4]:.3g}<br>Category %{customdata[8]}<extra>Click to show members</extra>", name="Significance"))
    label_radius = np.asarray([2.72 + (0.25 * (index % 2)) for index in range(n)])
    leader_theta: list[float | None] = []
    leader_radius: list[float | None] = []
    for angle, radius in zip(theta, label_radius):
        leader_theta.extend([float(angle), float(angle), None])
        leader_radius.extend([2.24, float(radius) - 0.10, None])
    polar.add_trace(go.Scatterpolar(theta=leader_theta, r=leader_radius, mode="lines", line={"color":"rgba(69,83,75,.76)","width":1.25}, hoverinfo="skip", showlegend=False))
    # Plotly's text-position direction is relative to the anchor point. Text on
    # the right half must extend right, and text on the left half must extend
    # left; the previous mapping was reversed and pushed labels into the rings.
    text_positions = ["middle right" if (angle <= 90 or angle >= 270) else "middle left" for angle in theta]
    polar.add_trace(go.Scatterpolar(theta=theta, r=label_radius, mode="text", text=labels, textposition=text_positions, customdata=custom, textfont={"size": 9}, hovertemplate="<b>%{customdata[2]}</b><extra>Click to show members</extra>", showlegend=False))
    polar.update_layout(title={"text":""}, meta={"bra_kind":"enrichment_circos"}, polar={"domain":{"x":[.04,.82],"y":[.035,.98]},"radialaxis": {"visible": False, "range": [0, 3.48], "showgrid": False}, "angularaxis": {"visible": False, "direction": "clockwise", "showgrid": False}}, legend={"orientation": "h", "y": -0.04, "x": 0.43, "xanchor": "center"}, height=780, margin={"l":56,"r":235,"t":16,"b":68})
    circ_table = pd.DataFrame({"term_id": circ[id_col], "term_name": circ["label"], "adjusted_p": pd.to_numeric(circ[padj_col], errors="coerce"), "minus_log10_adjusted_p": sig, "rich_factor": rich, "upregulated_genes": up, "downregulated_genes": down, "category": circ["plot_category"]})
    circ_table.to_csv(output_dir / "enrichment_circos_summary.tsv", sep="\t", index=False)
    write_plot(polar, output_dir / "enrichment_circos_interactive.html")
    created.append("enrichment_circos_interactive.html")
    return created


def _go_dag_focus_context(result: pd.DataFrame, nodes: pd.DataFrame, edges: pd.DataFrame, mapping: pd.DataFrame, output_dir: Path) -> list[str]:
    graphs = _go_graphs(nodes, edges)
    term_names = dict(zip(nodes["GO_ID"].astype(str), nodes["term"].astype(str)))
    branch_by_term = dict(zip(nodes["GO_ID"].astype(str), nodes["ontology"].astype(str)))
    result_id = first_existing(result, ["ID", "term_id", "pathway"])
    padj_col = first_existing(result, ["p.adjust", "padj", "FDR", "qvalue"])
    p_col = first_existing(result, ["pvalue", "PValue"]) or padj_col
    if not result_id or not padj_col:
        return []
    work = result.copy(); work[result_id] = work[result_id].astype(str); work[padj_col] = pd.to_numeric(work[padj_col], errors="coerce")
    if p_col: work[p_col] = pd.to_numeric(work[p_col], errors="coerce")
    result_lookup = work.set_index(result_id, drop=False).to_dict(orient="index")
    map_branch = mapping.copy(); map_branch["ontology"] = map_branch["term_id"].map(branch_by_term)
    level_rows: list[dict] = []; focus_rows: list[dict] = []; branch_payload: dict[str, dict] = {}
    for branch in ("BP", "MF", "CC"):
        graph = graphs[branch]
        if graph.number_of_nodes() == 0: continue
        root = GO_ROOTS[branch]; levels = _go_levels(graph, root)
        branch_map = map_branch.loc[map_branch["ontology"].eq(branch) & map_branch["term_id"].isin(levels)].copy()
        if not branch_map.empty:
            branch_map["level"] = branch_map["term_id"].map(levels)
            for level, frame in branch_map.groupby("level", dropna=True):
                level_rows.append({"ontology": branch, "level": int(level), "annotation_count": int(len(frame)), "unique_terms": int(frame["term_id"].nunique()), "unique_genes": int(frame["gene_id"].nunique()), "genes": "/".join(sorted(set(frame["gene_id"].astype(str))))})
        candidates = work.loc[work[result_id].map(branch_by_term).eq(branch)].sort_values(padj_col, na_position="last")
        if candidates.empty: continue
        qcut = candidates.loc[candidates[padj_col].le(0.05)]
        selected = (qcut if not qcut.empty else candidates).head(18)[result_id].astype(str).tolist()
        include: set[str] = set(selected)
        for term in selected:
            if term in graph: include.update(nx.ancestors(graph, term))
        if len(include) > 220:
            pruned: set[str] = set(selected)
            for term in selected:
                if root in graph and term in graph:
                    try:
                        for path in nx.all_simple_paths(graph, root, term, cutoff=max(levels.get(term, 1), 1)):
                            pruned.update(path)
                            if len(pruned) >= 220: break
                    except Exception: pass
                if len(pruned) >= 220: break
            include = pruned
        sub = graph.subgraph(include).copy()
        groups: dict[int, list[str]] = defaultdict(list)
        for node in sub.nodes(): groups[int(levels.get(node, 0))].append(node)
        positions: dict[str, tuple[float, float]] = {}
        max_width=max((len(v) for v in groups.values()), default=1)
        for level in sorted(groups):
            items = sorted(groups[level], key=lambda x: (term_names.get(x, x).casefold(), x))
            # Wider coordinates plus the iframe's internal scroll area prevent labels
            # from being compressed into one unreadable column.
            xs = [0.0] if len(items)==1 else np.linspace(-max(1.0,max_width/5), max(1.0,max_width/5), len(items)).tolist()
            for x, node in zip(xs, items): positions[node]=(float(x), -float(level)*1.35)
        direct_sets = branch_map.groupby("term_id")["gene_id"].apply(lambda s: set(s.astype(str))).to_dict() if not branch_map.empty else {}
        node_genes: dict[str, set[str]] = {}
        for node in sub.nodes():
            descendants = nx.descendants(graph, node) | {node}
            genes: set[str] = set()
            for term in descendants: genes.update(direct_sets.get(term, set()))
            node_genes[node] = genes
        branch_payload[branch] = {"graph": sub, "positions": positions, "levels": levels, "selected": set(selected), "node_genes": node_genes}
        for node in sub.nodes():
            row = result_lookup.get(node, {}); q = pd.to_numeric(pd.Series([row.get(padj_col)]), errors="coerce").iloc[0] if row else np.nan; pv = pd.to_numeric(pd.Series([row.get(p_col)]), errors="coerce").iloc[0] if row and p_col else np.nan
            focus_rows.append({"ontology": branch, "GO_ID": node, "term": term_names.get(node,node), "level": int(levels.get(node,0)), "is_reported_term": node in result_lookup, "is_focus_term": node in set(selected), "adjusted_p": q, "pvalue": pv, "mapped_genes": len(node_genes[node]), "genes": "/".join(sorted(node_genes[node]))})
    if not branch_payload: return []
    pd.DataFrame(level_rows).to_csv(output_dir / "go_level_distribution.tsv", sep="\t", index=False)
    pd.DataFrame(focus_rows).to_csv(output_dir / "go_dag_focus_nodes.tsv", sep="\t", index=False)

    fig = make_subplots(rows=1, cols=2, column_widths=[0.78,0.22], horizontal_spacing=0.06)
    for branch in ("BP","MF","CC"):
        payload=branch_payload.get(branch)
        if not payload: continue
        sub=payload["graph"]; pos=payload["positions"]; selected=payload["selected"]; node_genes=payload["node_genes"]
        edge_x=[]; edge_y=[]
        for parent,child in sub.edges():
            if parent in pos and child in pos:
                x0,y0=pos[parent]; x1,y1=pos[child]; edge_x.extend([x0,x1,None]); edge_y.extend([y0,y1,None])
        fig.add_trace(go.Scatter(x=edge_x,y=edge_y,mode="lines",line={"width":1,"color":"rgba(70,70,70,.34)"},hoverinfo="skip",showlegend=False,visible=branch=="BP",meta={"bra_view":"dag","bra_branch":branch,"bra_role":"edges"}),row=1,col=1)
        for node_list,is_query in (([n for n in sub.nodes() if n not in selected],False),([n for n in sub.nodes() if n in selected],True)):
            xs=[];ys=[];hover=[];texts=[];scores=[];sizes=[];custom=[]
            for node in node_list:
                x,y=pos[node]; xs.append(x);ys.append(y); row=result_lookup.get(node,{}); q=pd.to_numeric(pd.Series([row.get(padj_col)]),errors="coerce").iloc[0] if row else np.nan; score=float(-math.log10(max(float(q),np.finfo(float).tiny))) if np.isfinite(q) and q>=0 else 0.0; scores.append(score)
                genes=sorted(node_genes.get(node,set())); gc=len(genes); sizes.append(13+min(14,math.sqrt(max(0,gc))*1.35)); name=term_names.get(node,node)
                hover.append(f"<b>{name}</b><br>{node}<br>{GO_BRANCH_NAMES[branch]}<br>Level {payload['levels'].get(node,0)}<br>Mapped genes {gc}"+(f"<br>Adjusted p {q:.3g}" if np.isfinite(q) else "")+"<br><b>Click to show genes/proteins in the linked spreadsheet</b>")
                # Ancestors remain clean markers. Only enriched terms receive short,
                # wrapped labels; the complete text is always available on hover.
                texts.append(_wrap_plot_label(name, 24, 3) if is_query else "")
                custom.append(["BRA_SELECTION",node,name,"/".join(genes)])
            marker={"size":sizes,"symbol":"square" if is_query else "circle","line":{"width":1,"color":"#444"}}
            if is_query: marker.update({"color":scores,"colorscale":"YlOrRd","showscale":True,"colorbar":{"title":{"text":"−log₁₀ adjusted p","side":"right"},"x":.81,"xanchor":"left","y":.48,"len":.34,"thickness":13}})
            else: marker.update({"color":"#fff3a6"})
            fig.add_trace(go.Scatter(x=xs,y=ys,mode="markers+text" if is_query else "markers",marker=marker,text=texts,textposition="top center",textfont={"size":10},customdata=custom,hovertext=hover,hoverinfo="text",name="Enriched terms" if is_query else "Ancestors",showlegend=True,visible=branch=="BP",meta={"bra_view":"dag","bra_branch":branch,"bra_role":"focus" if is_query else "ancestor"}),row=1,col=1)
        context=pd.DataFrame(level_rows); context=context.loc[context["ontology"].eq(branch)].sort_values("level") if not context.empty else pd.DataFrame()
        context_custom=[["BRA_SELECTION",f"GO_LEVEL_{branch}_{int(r.level)}",f"{GO_BRANCH_NAMES[branch]} · level {int(r.level)}",str(r.genes),int(r.unique_terms),int(r.unique_genes)] for r in context.itertuples()] if not context.empty else []
        fig.add_trace(go.Bar(x=context["annotation_count"] if not context.empty else [],y=context["level"] if not context.empty else [],orientation="h",marker={"color":GO_BRANCH_COLORS[branch]},selected={"marker":{"color":"#7b2cbf","opacity":1.0}},unselected={"marker":{"opacity":0.30}},customdata=context_custom,hovertemplate=f"{GO_BRANCH_NAMES[branch]}<br>GO level %{{y}}<br>Mapped annotations %{{x}}<br>Unique terms %{{customdata[4]}}<br>Unique genes %{{customdata[5]}}<extra>Click to show genes/proteins at this ontology level</extra>",name=GO_BRANCH_NAMES[branch],showlegend=False,visible=False,meta={"bra_view":"context","bra_branch":branch}),row=1,col=2)
    fig.update_layout(title={"text":""},meta={"bra_kind":"go_dag"},height=900,hovermode="closest",margin={"l":45,"r":145,"t":30,"b":45},legend={"x":.01,"y":.99,"xanchor":"left","yanchor":"top","bgcolor":"rgba(255,255,255,.82)"},barmode="group")
    fig.update_xaxes(visible=False,row=1,col=1);fig.update_yaxes(visible=False,row=1,col=1)
    fig.update_yaxes(title_text="GO level",autorange="reversed",row=1,col=2)
    fig.update_xaxes(title_text="",row=1,col=2)
    write_plot(fig,output_dir/"go_dag_interactive.html")
    return ["go_dag_interactive.html"]


def _go_annotation_landscape(config: dict, nodes: pd.DataFrame, edges: pd.DataFrame, mapping: pd.DataFrame, output_dir: Path) -> list[str]:
    graphs=_go_graphs(nodes,edges); branch_by_term=dict(zip(nodes["GO_ID"].astype(str),nodes["ontology"].astype(str))); term_name=dict(zip(nodes["GO_ID"].astype(str),nodes["term"].astype(str)))
    levels_by_branch={branch:_go_levels(graphs[branch],GO_ROOTS[branch]) for branch in ("BP","MF","CC")}
    map_work=mapping.copy(); map_work["ontology"]=map_work["term_id"].map(branch_by_term); map_work["level"]=[levels_by_branch.get(str(branch),{}).get(str(term),np.nan) for term,branch in zip(map_work["term_id"],map_work["ontology"])]
    level_summary=map_work.dropna(subset=["ontology","level"]).groupby(["ontology","level"],as_index=False).agg(annotation_count=("gene_id","size"),unique_terms=("term_id","nunique"),unique_genes=("gene_id","nunique"))
    if not level_summary.empty: level_summary["level"]=level_summary["level"].astype(int); level_summary.to_csv(output_dir/"go_level_distribution.tsv",sep="\t",index=False)
    category_rows=[]; category_gene_sets: dict[tuple[str,str], set[str]] = defaultdict(set)
    for branch in ("BP","MF","CC"):
        graph=graphs[branch];root=GO_ROOTS[branch]
        if root not in graph: continue
        root_children=set(graph.successors(root)); branch_rows=map_work.loc[map_work["ontology"].eq(branch)];weights=defaultdict(float)
        for _,row in branch_rows.iterrows():
            term=str(row["term_id"])
            if term not in graph: continue
            categories=sorted(root_children & (set(nx.ancestors(graph,term))|{term}))
            gene=str(row["gene_id"])
            if not categories: weights["OTHER"]+=1.0; category_gene_sets[(branch,"OTHER")].add(gene)
            else:
                share=1.0/len(categories)
                for cat in categories: weights[cat]+=share; category_gene_sets[(branch,cat)].add(gene)
        total=sum(weights.values()) or 1.0
        for cat,weight in sorted(weights.items(),key=lambda item:item[1],reverse=True): category_rows.append({"ontology":branch,"category_id":cat,"category_name":"Other / unclassified" if cat=="OTHER" else term_name.get(cat,cat),"annotation_weight":weight,"percent":100.0*weight/total,"genes":"/".join(sorted(category_gene_sets.get((branch,cat),set())))})
    category_summary=pd.DataFrame(category_rows)
    if not category_summary.empty: category_summary.to_csv(output_dir/"go_category_summary.tsv",sep="\t",index=False)
    lengths=_discover_gene_lengths(config); gene_length_summary=pd.DataFrame()
    if not lengths.empty:
        distinct=map_work.dropna(subset=["ontology"]).drop_duplicates(["gene_id","term_id"]); total_counts=distinct.groupby("gene_id")["term_id"].nunique().rename("go_term_count"); branch_counts=distinct.pivot_table(index="gene_id",columns="ontology",values="term_id",aggfunc="nunique",fill_value=0);gene_length_summary=lengths.merge(total_counts,left_on="gene_id",right_index=True,how="inner")
        for branch in ("BP","MF","CC"): gene_length_summary[f"{branch}_term_count"]=gene_length_summary["gene_id"].map(branch_counts[branch] if branch in branch_counts.columns else {}).fillna(0).astype(int)
        gene_length_summary.to_csv(output_dir/"go_gene_length_annotations.tsv",sep="\t",index=False)

    fig=go.Figure()
    gene_annotations=[]
    if not gene_length_summary.empty:
        bins=min(80,max(20,int(math.sqrt(len(gene_length_summary))*2))); lengths_array=pd.to_numeric(gene_length_summary["length_bp"],errors="coerce").to_numpy(dtype=float); edges=np.histogram_bin_edges(lengths_array,bins=bins); mids=(edges[:-1]+edges[1:])/2; values=[]; custom=[]
        for i,(left,right) in enumerate(zip(edges[:-1],edges[1:])):
            mask=(lengths_array>=left)&((lengths_array<=right) if i==len(edges)-2 else (lengths_array<right)); frame=gene_length_summary.loc[mask]; total=float(pd.to_numeric(frame["go_term_count"],errors="coerce").fillna(0).sum()); genes="/".join(sorted(set(frame["gene_id"].astype(str)))); values.append(total); custom.append(["BRA_SELECTION",f"GENE_LENGTH_{int(round(left))}_{int(round(right))}",f"Gene length {int(round(left))}–{int(round(right))} bp",genes])
        fig.add_trace(go.Bar(x=mids,y=values,width=np.diff(edges)*.92,marker={"color":"#5a3d7a"},selected={"marker":{"color":"#7b2cbf","opacity":1.0}},unselected={"marker":{"opacity":0.30}},customdata=custom,hovertemplate="Gene length %{x:.0f} bp<br>Total GO annotations %{y:.0f}<extra>Click to show genes/proteins in this length bin</extra>",visible=True,showlegend=False,meta={"bra_view":"gene_length"}))
    else:
        # Keep a tiny invisible trace so the view remains selectable and place the
        # status message in the top margin rather than over the graph itself.
        fig.add_trace(go.Scatter(x=[],y=[],mode="markers",visible=True,showlegend=False,meta={"bra_view":"gene_length"}))
        gene_annotations=[{"xref":"paper","yref":"paper","x":.5,"y":1.04,"text":"Gene lengths were not found in the selected RNA-processing handoff. The software now checks gene_lengths.tsv, features.saf, coordinate tables and configured GFF/GTF files.","showarrow":False,"font":{"size":11,"color":"#66736b"},"xanchor":"center"}]
    category_annotations=[]
    domains=[(0.00,0.31),(0.345,0.655),(0.69,1.00)]
    for idx,branch in enumerate(("CC","BP","MF")):
        subset=category_summary.loc[category_summary["ontology"].eq(branch)].copy() if not category_summary.empty else pd.DataFrame()
        if not subset.empty:
            subset=subset.sort_values("annotation_weight",ascending=False); keep=subset.head(7).copy(); remainder=subset.iloc[7:]
            if not remainder.empty:
                remainder_genes=set();
                for raw in remainder.get("genes",pd.Series(dtype=str)).fillna("").astype(str): remainder_genes.update(parse_gene_set(raw))
                keep=pd.concat([keep,pd.DataFrame([{"ontology":branch,"category_id":"OTHER_SMALL","category_name":"Other categories","annotation_weight":remainder["annotation_weight"].sum(),"percent":remainder["percent"].sum(),"genes":"/".join(sorted(remainder_genes))}])],ignore_index=True)
            pie_custom=[["BRA_SELECTION",str(r.category_id),str(r.category_name),str(getattr(r,"genes",""))] for r in keep.itertuples()]
            fig.add_trace(go.Pie(labels=keep["category_name"],values=keep["annotation_weight"],customdata=pie_custom,hole=.28,textinfo="percent",textposition="inside",insidetextfont={"size":11},hovertemplate="%{label}<br>Annotation share %{percent}<extra>Click to show member genes/proteins</extra>",name=branch,showlegend=False,sort=False,domain={"x":list(domains[idx]),"y":[.08,.93]},visible=False,meta={"bra_view":"categories"}))
        else:
            fig.add_trace(go.Pie(labels=["No mapped terms"],values=[1],textinfo="label",marker={"colors":["#eeeeee"]},showlegend=False,hoverinfo="skip",domain={"x":list(domains[idx]),"y":[.08,.93]},visible=False,meta={"bra_view":"categories"}))
        category_annotations.append({"xref":"paper","yref":"paper","x":sum(domains[idx])/2,"y":.98,"text":f"C{idx+1}. {GO_BRANCH_NAMES[branch]}","showarrow":False,"font":{"size":13},"xanchor":"center"})
    fig.update_layout(title={"text":""},meta={"bra_kind":"go_landscape","bra_gene_annotations":gene_annotations,"bra_category_annotations":category_annotations},height=760,margin={"l":90,"r":45,"t":55,"b":110},xaxis={"title":{"text":"Gene length (bp)","standoff":18},"visible":True,"automargin":True},yaxis={"title":{"text":"Number of GO annotations","standoff":14},"visible":True,"automargin":True})
    write_plot(fig,output_dir/"go_annotation_landscape_interactive.html")
    return ["go_annotation_landscape_interactive.html"]


def _go_semantic_similarity(result: pd.DataFrame, nodes: pd.DataFrame, edges: pd.DataFrame, mapping: pd.DataFrame, output_dir: Path, config: dict) -> list[str]:
    result_id = first_existing(result, ["ID", "term_id", "pathway"])
    padj_col = first_existing(result, ["p.adjust", "padj", "FDR", "qvalue"])
    if not result_id or not padj_col or result.empty:
        return []
    branch_by_term = dict(zip(nodes["GO_ID"].astype(str), nodes["ontology"].astype(str)))
    term_name = dict(zip(nodes["GO_ID"].astype(str), nodes["term"].astype(str)))
    work = result.copy(); work[result_id] = work[result_id].astype(str); work[padj_col] = pd.to_numeric(work[padj_col], errors="coerce")
    work = work.loc[work[result_id].isin(branch_by_term)].sort_values(padj_col, na_position="last")
    if len(work) < 2: return []
    # A square heatmap with full biological names cannot fit sixteen long names
    # on both axes inside the fixed linked-report viewport. Keep the ten strongest
    # terms in the visual summary; every term remains available in the exported
    # matrix and linked spreadsheet.
    maximum = max(6, min(10, int(config.get("go_similarity_terms", 10))))
    sig = work.loc[work[padj_col].le(0.05)]
    chosen = (sig if len(sig) >= 10 else work).head(maximum).drop_duplicates(result_id)
    terms = chosen[result_id].astype(str).tolist(); q_lookup = dict(zip(work[result_id].astype(str), work[padj_col])); graphs = _go_graphs(nodes, edges)
    map_direct = mapping.loc[mapping["term_id"].isin(branch_by_term)].drop_duplicates(["gene_id", "term_id"])
    all_node_genes: dict[str, set[str]] = defaultdict(set)
    for _, row in map_direct.iterrows(): all_node_genes[str(row["term_id"])].add(str(row["gene_id"]))
    ancestor_sets: dict[str, set[str]] = {}; ic: dict[str, float] = {}
    for branch in ("BP", "MF", "CC"):
        graph = graphs[branch]
        if graph.number_of_nodes() == 0: continue
        try: topo = list(nx.topological_sort(graph))
        except nx.NetworkXUnfeasible: topo = list(graph.nodes())
        for node in reversed(topo):
            for parent in graph.predecessors(node): all_node_genes[parent].update(all_node_genes[node])
        root = GO_ROOTS[branch]; root_n = max(1, len(all_node_genes[root]))
        for node in graph.nodes():
            n = len(all_node_genes[node]); ic[node] = max(0.0, -math.log((n + 1.0) / (root_n + 1.0)))
        ancestor_sets.update(_go_ancestor_sets(graph, [t for t in terms if branch_by_term.get(t) == branch]))
    n = len(terms); matrix = np.zeros((n, n), dtype=float)
    for i, left in enumerate(terms):
        matrix[i, i] = 1.0
        for j in range(i + 1, n):
            right = terms[j]
            if branch_by_term.get(left) != branch_by_term.get(right): sim = 0.0
            else:
                common = ancestor_sets.get(left, {left}) & ancestor_sets.get(right, {right}); mica = max((ic.get(node, 0.0) for node in common), default=0.0); denom = ic.get(left, 0.0) + ic.get(right, 0.0); sim = 2.0 * mica / denom if denom > 0 else 0.0; sim = min(1.0, max(0.0, sim))
            matrix[i, j] = matrix[j, i] = sim
    sim_graph = nx.Graph(); sim_graph.add_nodes_from(range(n))
    for i in range(n):
        for j in range(i + 1, n):
            if matrix[i, j] >= 0.45: sim_graph.add_edge(i, j, weight=float(matrix[i, j]))
    try: communities = list(nx.community.greedy_modularity_communities(sim_graph, weight="weight")) if sim_graph.number_of_edges() else [{i} for i in range(n)]
    except Exception: communities = [{i} for i in range(n)]
    communities = sorted(communities, key=lambda c: (-len(c), min(c)))
    stopwords = {"process", "activity", "regulation", "positive", "negative", "cellular", "molecular", "biological", "of", "the", "to", "in", "via", "pathway", "protein", "gene"}
    cluster_meta: list[dict] = []; cluster_for_index: dict[int, int] = {}; cluster_label: dict[int, str] = {}
    for cid, members in enumerate(communities, start=1):
        words = Counter()
        for idx in members:
            for token in re.findall(r"[A-Za-z][A-Za-z0-9-]{2,}", term_name.get(terms[idx], terms[idx]).casefold()):
                if token not in stopwords: words[token] += 1
        common = [word for word, _ in words.most_common(3)]; label = " / ".join(common[:2]) if common else GO_BRANCH_NAMES.get(branch_by_term.get(terms[min(members)], ""), f"Cluster {cid}"); cluster_label[cid] = label
        for idx in members: cluster_for_index[idx] = cid
    order = sorted(range(n), key=lambda i: (cluster_for_index.get(i, 9999), branch_by_term.get(terms[i], ""), q_lookup.get(terms[i], 1.0), term_name.get(terms[i], terms[i])))
    ordered_terms = [terms[i] for i in order]; ordered_matrix = matrix[np.ix_(order, order)]
    for new_pos, old_idx in enumerate(order):
        cid = cluster_for_index.get(old_idx, 0); cluster_meta.append({"order": new_pos + 1, "cluster": f"G-C{cid}", "cluster_label": cluster_label.get(cid, ""), "term_id": terms[old_idx], "term_name": term_name.get(terms[old_idx], terms[old_idx]), "ontology": branch_by_term.get(terms[old_idx], ""), "adjusted_p": q_lookup.get(terms[old_idx], np.nan)})
    cluster_df = pd.DataFrame(cluster_meta); cluster_df.to_csv(output_dir / "go_semantic_similarity_clusters.tsv", sep="\t", index=False)
    sim_df = pd.DataFrame(ordered_matrix, index=ordered_terms, columns=ordered_terms); sim_df.index.name = "term_id"; sim_df.to_csv(output_dir / "go_semantic_similarity_matrix.tsv", sep="\t")
    labels = [term_name.get(term, term) for term in ordered_terms]
    positions = list(range(1, n + 1))
    heat_custom = np.empty((n, n, 4), dtype=object)
    for row_index in range(n):
        for column_index in range(n):
            heat_custom[row_index, column_index] = [
                labels[column_index], ordered_terms[column_index],
                labels[row_index], ordered_terms[row_index],
            ]
    fig = go.Figure(go.Heatmap(
        z=ordered_matrix, x=positions, y=positions, customdata=heat_custom,
        zmin=0, zmax=1, colorscale="Reds",
        colorbar={"title": {"text": "Lin similarity", "side": "right"}, "x": 1.035, "xanchor": "left", "len": 0.72, "thickness": 14},
        hovertemplate="GO term X %{customdata[0]}<br>%{customdata[1]}<br>GO term Y %{customdata[2]}<br>%{customdata[3]}<br>Semantic similarity %{z:.3f}<extra></extra>",
    ))
    # Do not draw cluster-boundary lines over the matrix.  When many terms form
    # singleton clusters those lines become a full cell grid and compete with
    # the heatmap signal. Cluster membership remains in hover/exported tables.
    fig.update_layout(title={"text":""},height=780,margin={"l":340,"r":155,"t":24,"b":82},shapes=[])
    fig.update_xaxes(
        title_text="GO term number (same order as rows)", title_standoff=12,
        tickmode="array", tickvals=positions, ticktext=[str(value) for value in positions],
        tickangle=0, tickfont={"size":10}, automargin=True, showgrid=False,
    )
    fig.update_yaxes(
        title_text="", tickmode="array", tickvals=positions,
        ticktext=[f"{index}. {_wrap_full_plot_label(label, 34)}" for index, label in enumerate(labels, start=1)],
        tickfont={"size":9}, autorange="reversed", automargin=True, showgrid=False,
    )
    write_plot(fig, output_dir / "go_semantic_similarity_interactive.html")
    return ["go_semantic_similarity_interactive.html"]


def _go_cellular_component_schematic(nodes: pd.DataFrame, edges: pd.DataFrame, mapping: pd.DataFrame, output_dir: Path) -> list[str]:
    graph = _go_graphs(nodes, edges)["CC"]
    if graph.number_of_nodes() == 0:
        return []
    branch_by_term = dict(zip(nodes["GO_ID"].astype(str), nodes["ontology"].astype(str)))
    cc_map = mapping.loc[mapping["term_id"].map(branch_by_term).eq("CC")].drop_duplicates(["gene_id", "term_id"])

    # The fixed anatomical layer is derived directly from the supplied reference
    # illustration and recolored to the suite palette.  The coordinates below are
    # pixel coordinates on that image, so every arrowhead is pinned to the real
    # structure.  Users may drag the label end without moving that anchor.
    canonical = [
        # The first six arrowheads follow the visible upper-left envelope
        # layers from outside to inside.  This keeps each leader on its own
        # anatomical target instead of crossing several membranes.
        ("Capsule", "GO:0042603", (560, 210), (840, 210), True, "center"),
        ("Cell envelope", "GO:0030313", (475, 305), (170, 470), True, "center"),
        ("Outer membrane", "GO:0019867", (535, 244), (660, 130), True, "center"),
        ("Cell wall", "GO:0005618", (505, 275), (150, 310), True, "center"),
        ("Periplasmic space", "GO:0042597", (445, 335), (135, 575), True, "center"),
        ("Plasma membrane", "GO:0005886", (415, 365), (210, 720), True, "center"),
        ("Cytoplasm", "GO:0005737", (990, 385), (1140, 60), True, "center"),
        ("Cytosol", "GO:0005829", (1060, 445), (1350, 150), True, "center"),
        ("Ribosome", "GO:0005840", (1110, 475), (1500, 410), True, "center"),
        ("Pilus / fimbria", "GO:0009289", (1235, 350), (1490, 240), True, "center"),
        ("Bacterial-type flagellum", "GO:0009288", (1370, 500), (1420, 690), True, "center"),
        ("Nucleoid", "GO:0009295", (720, 500), (620, 820), True, "center"),
        ("Plasmid / extrachromosomal circular DNA", "GO:0005727", (1040, 525), (1240, 790), True, "center"),
        ("Extracellular region", "GO:0005576", (np.nan, np.nan), (500, 885), False, "center"),
    ]
    direct = cc_map.groupby("term_id")["gene_id"].apply(lambda values: set(values.astype(str))).to_dict() if not cc_map.empty else {}
    gene_sets = {go_id: set() for _, go_id, *_rest in canonical}
    for _, go_id, *_rest in canonical:
        if go_id in graph:
            for term in nx.descendants(graph, go_id) | {go_id}:
                gene_sets[go_id].update(direct.get(term, set()))
    assigned = set().union(*gene_sets.values()) if gene_sets else set()
    other = set(cc_map["gene_id"].astype(str)) - assigned
    rows = [
        {
            "compartment": label, "GO_ID": go_id,
            "gene_count": len(gene_sets[go_id]), "genes": "/".join(sorted(gene_sets[go_id])),
            "anchor_x": anchor[0], "anchor_y": anchor[1],
            "label_x": label_position[0], "label_y": label_position[1],
            "draw_line": draw_line, "label_side": label_side,
        }
        for label, go_id, anchor, label_position, draw_line, label_side in canonical
    ]
    rows.append({"compartment": "Other cellular component", "GO_ID": "", "gene_count": len(other), "genes": "/".join(sorted(other)), "anchor_x": np.nan, "anchor_y": np.nan, "label_x": 1030, "label_y": 885, "draw_line": False, "label_side": "center"})
    summary = pd.DataFrame(rows)
    summary.to_csv(output_dir / "go_cellular_component_summary.tsv", sep="\t", index=False)

    asset = Path(__file__).resolve().parents[3] / "App" / "assets" / "bacterial_cell_component_base.png"
    if not asset.is_file():
        return []
    source = "data:image/png;base64," + base64.b64encode(asset.read_bytes()).decode("ascii")
    fig = go.Figure()
    fig.add_layout_image(source=source, xref="x", yref="y", x=0, y=0, sizex=1672, sizey=941, xanchor="left", yanchor="top", sizing="stretch", opacity=1.0, layer="below")
    annotations: list[dict] = []
    selections: list[list[str]] = []

    for row in summary.itertuples():
        count = int(row.gene_count)
        text = f"<b>{row.compartment}</b>  ({count} mapped genes)"
        common = {
            "text": text, "font": {"size": 11, "color": "#173426"},
            "bgcolor": "rgba(255,255,255,0)", "bordercolor": "rgba(0,0,0,0)",
            "borderwidth": 0, "borderpad": 0, "captureevents": True,
            "align": "center", "name": f"BRA_CELL::{row.compartment}",
        }
        if bool(row.draw_line) and np.isfinite(float(row.anchor_x)) and np.isfinite(float(row.anchor_y)):
            annotation = {
                **common, "x": float(row.anchor_x), "y": float(row.anchor_y),
                "xref": "x", "yref": "y", "ax": float(row.label_x), "ay": float(row.label_y),
                "axref": "x", "ayref": "y", "showarrow": True,
                "arrowhead": 2, "arrowsize": 0.85, "arrowwidth": 1.55,
                "arrowcolor": "#52665b", "standoff": 3, "startstandoff": 0,
                "xanchor": "center", "yanchor": "middle",
            }
        else:
            annotation = {**common, "x": float(row.label_x), "y": float(row.label_y), "xref": "x", "yref": "y", "showarrow": False, "xanchor": "center", "yanchor": "middle"}
        annotations.append(annotation)
        selections.append(["BRA_SELECTION", str(row.GO_ID), str(row.compartment), str(row.genes)])
    fig.update_layout(
        title={"text": ""}, annotations=annotations,
        meta={"bra_kind": "go_cellular_component", "bra_annotation_selections": selections},
        xaxis={"range": [0, 1672], "visible": False, "fixedrange": True},
        yaxis={"range": [941, -20], "visible": False, "fixedrange": True, "scaleanchor": "x", "scaleratio": 1},
        height=720, margin={"l": 8, "r": 8, "t": 8, "b": 8},
    )
    write_plot(fig, output_dir / "go_cellular_component_interactive.html")
    return ["go_cellular_component_interactive.html"]


def go_supplemental_plots(config: dict, enrichment_result: pd.DataFrame, output_dir: Path) -> list[str]:
    """GO-specific topology, annotation-landscape, semantic, and bacterial CC views."""
    nodes, edges, mapping = _go_support_tables(output_dir)
    if nodes.empty or edges.empty or mapping.empty:
        return []
    created: list[str] = []
    created.extend(_go_dag_focus_context(enrichment_result, nodes, edges, mapping, output_dir))
    created.extend(_go_annotation_landscape(config, nodes, edges, mapping, output_dir))
    created.extend(_go_semantic_similarity(enrichment_result, nodes, edges, mapping, output_dir, config))
    created.extend(_go_cellular_component_schematic(nodes, edges, mapping, output_dir))
    return list(dict.fromkeys(created))

def enrichment_plots(config: dict) -> list[str]:
    output_dir = Path(config["output_dir"])
    # ``result_file`` in the enrichment configuration is the upstream DE table
    # used to select genes.  The R enrichment engine writes its own result table
    # to ``enrichment_results.tsv``.  Using config["result_file"] here therefore
    # makes the plot stage reopen the DE input and fail because it has no GO/pathway
    # term columns.  Keep a dedicated optional override for future callers, while
    # defaulting unambiguously to the enrichment output produced immediately before
    # this plotting step.
    result_path = config.get("enrichment_result_file") or str(output_dir / "enrichment_results.tsv")
    result = read_table(result_path)
    selected = plot_selection(config, {"bar", "dot", "enrichment_map", "gene_term"})
    created: list[str] = []
    id_col = first_existing(result, ["ID", "term_id", "pathway_id", "pathway"])
    desc_col = first_existing(result, ["Description", "term_name", "pathway_name", "pathway"])
    padj_col = first_existing(result, ["p.adjust", "p_adjust_BH", "padj", "FDR", "qvalue"])
    if not id_col or not padj_col:
        raise ValueError("The enrichment result must contain term and adjusted-p-value columns.")
    if not desc_col:
        desc_col = id_col
    result[padj_col] = pd.to_numeric(result[padj_col], errors="coerce")
    result["minus_log10_adjusted_p"] = safe_neg_log10(result[padj_col])
    result["label"] = result[desc_col].fillna(result[id_col]).astype(str)
    genes_col_all = first_existing(result, ["geneID", "genes", "leadingEdge", "leading_edge", "core_enrichment"])
    result["__bra_term"] = result[id_col].astype(str)
    result["__bra_label"] = result["label"].astype(str)
    result["__bra_genes"] = result[genes_col_all].fillna("").astype(str) if genes_col_all else ""
    # Keep specialized bar/dot figures readable when fitted into the one-page
    # interactive viewport. The complete term set remains in the linked sheet.
    top_terms = max(5, min(14, int(config.get("top_terms", 30))))
    result = result.sort_values(padj_col, na_position="last").head(top_terms).copy()
    count_col = first_existing(result, ["Count", "setSize", "size"])
    nes_col = first_existing(result, ["NES", "enrichmentScore"])
    if count_col:
        result[count_col] = pd.to_numeric(result[count_col], errors="coerce").fillna(1)
    else:
        result["Count"] = 1
        count_col = "Count"

    if "bar" in selected:
        bar_color = first_existing(result, ["ontology", "Category", "category"]) or (nes_col if nes_col else None)
        bar_frame = result.sort_values([bar_color, "minus_log10_adjusted_p"], kind="stable") if bar_color and not pd.api.types.is_numeric_dtype(result[bar_color]) else result.sort_values("minus_log10_adjusted_p")
        fig = px.bar(
            bar_frame,
            x="minus_log10_adjusted_p",
            y="label",
            orientation="h",
            color=bar_color,
            custom_data=["__bra_term", "__bra_label", "__bra_genes", count_col, padj_col],
            labels={"minus_log10_adjusted_p": "−log₁₀ adjusted p-value", "label": "Term"},
            title="Top enriched terms and pathways",
        )
        fig.for_each_trace(lambda tr: tr.update(customdata=[["BRA_SELECTION", *row] for row in tr.customdata] if tr.customdata is not None else tr.customdata, selected={"marker":{"color":"#7b2cbf","opacity":1.0}}, unselected={"marker":{"opacity":0.30}}, hovertemplate="<b>%{y}</b><br>Term ID %{customdata[1]}<br>−log₁₀ adjusted p %{x:.3f}<br>Adjusted p %{customdata[5]:.3g}<br>Mapped genes %{customdata[4]}<br><extra></extra>"))
        tickvals=bar_frame["label"].astype(str).tolist();fig.update_yaxes(tickmode="array",tickvals=tickvals,ticktext=[_wrap_full_plot_label(v,36) for v in tickvals],categoryorder="array",categoryarray=tickvals,automargin=True,domain=[.11,.995]);fig.update_xaxes(title_text="−log₁₀ adjusted p-value",title_standoff=12,automargin=True,showticklabels=True,domain=[0.0,.95]);fig.update_layout(title={"text":""},height=max(680,40*len(result)+145),margin={"l":255,"r":36,"t":18,"b":58})
        write_plot(fig, output_dir / "enrichment_bar_interactive.html")
        created.append("enrichment_bar_interactive.html")

    if "dot" in selected:
        dot_category = first_existing(result, ["ontology", "Category", "category"])
        dot_frame = result.sort_values([dot_category, "minus_log10_adjusted_p"], kind="stable") if dot_category else result.sort_values("minus_log10_adjusted_p")
        dot_color = nes_col if nes_col else "minus_log10_adjusted_p"
        fig = px.scatter(
            dot_frame,
            x="minus_log10_adjusted_p",
            y="label",
            size=count_col,
            color=dot_color,
            custom_data=["__bra_term", "__bra_label", "__bra_genes", count_col, padj_col],
            labels={"minus_log10_adjusted_p": "−log₁₀ adjusted p-value", "label": "Term"},
            title="Enrichment dot plot",
        )
        fig.for_each_trace(lambda tr: tr.update(customdata=[["BRA_SELECTION", *row] for row in tr.customdata] if tr.customdata is not None else tr.customdata, hovertemplate="<b>%{y}</b><br>Term ID %{customdata[1]}<br>−log₁₀ adjusted p %{x:.3f}<br>Adjusted p %{customdata[5]:.3g}<br>Mapped genes %{customdata[4]}<br><extra></extra>"))
        tickvals=dot_frame["label"].astype(str).tolist();fig.update_yaxes(tickmode="array",tickvals=tickvals,ticktext=[_wrap_full_plot_label(v,36) for v in tickvals],categoryorder="array",categoryarray=tickvals,automargin=True,domain=[.11,.995]);fig.update_xaxes(title_text="−log₁₀ adjusted p-value",title_standoff=12,automargin=True,showticklabels=True,domain=[0.0,.93]);fig.update_layout(title={"text":""},height=max(680,40*len(result)+145),margin={"l":255,"r":155,"t":18,"b":58},coloraxis_colorbar={"title":{"text":("NES" if nes_col else "−log₁₀ adjusted p"),"side":"right"},"x":1.025,"xanchor":"left","y":.55,"yanchor":"middle","len":.70,"thickness":18})
        write_plot(fig, output_dir / "enrichment_dot_interactive.html")
        created.append("enrichment_dot_interactive.html")

    genes_col = first_existing(result, ["geneID", "genes", "leadingEdge", "leading_edge", "core_enrichment"])
    network_limit = max(5, int(config.get("network_term_limit", 20)))
    network_result = result.head(network_limit)
    if "enrichment_map" in selected:
        graph = nx.Graph()
        term_genes: dict[str, set[str]] = {}
        for _, row in network_result.iterrows():
            term = str(row[id_col])
            term_genes[term] = parse_gene_set(row[genes_col]) if genes_col else set()
            graph.add_node(term, label=str(row["label"]), score=float(row["minus_log10_adjusted_p"]), term_id=term, genes="/".join(sorted(term_genes[term])))
        terms = list(term_genes)
        overlap_cutoff = float(config.get("overlap_cutoff", 0.15))
        for index, left in enumerate(terms):
            for right in terms[index + 1 :]:
                union = term_genes[left] | term_genes[right]
                overlap = term_genes[left] & term_genes[right]
                if union and len(overlap) / len(union) >= overlap_cutoff:
                    graph.add_edge(left, right, weight=len(overlap) / len(union))
        network_figure = network_figure_from_graph(graph, directed=False, title="")
        write_plot(network_figure, output_dir / "enrichment_network_interactive.html")
        created.append("enrichment_network_interactive.html")

    if "gene_term" in selected and genes_col:
        bipartite = nx.Graph()
        genes_per_term = max(5, int(config.get("genes_per_term", 60)))
        for _, row in network_result.iterrows():
            term = str(row[id_col])
            bipartite.add_node(term, label=str(row["label"]), kind="term", score=float(row["minus_log10_adjusted_p"]), term_id=term, genes="/".join(sorted(parse_gene_set(row[genes_col]))))
            for gene in list(parse_gene_set(row[genes_col]))[:genes_per_term]:
                bipartite.add_node(gene, label=gene, kind="gene", score=1.0, term_id="", genes=gene)
                bipartite.add_edge(term, gene, weight=1.0)
        gene_network = network_figure_from_graph(bipartite, directed=False, title="")
        write_plot(gene_network, output_dir / "gene_term_network_interactive.html")
        created.append("gene_term_network_interactive.html")
    full_result = read_table(result_path)
    created.extend(_enrichment_richfactor_and_circos(config, full_result, output_dir))
    created.extend(gsea_supplemental_plots(config, full_result, output_dir))
    created.extend(go_supplemental_plots(config, full_result, output_dir))
    return list(dict.fromkeys(created))


def network_figure_from_graph(
    graph: nx.Graph,
    directed: bool,
    title: str,
    layout_name: str = "spring",
    show_labels: bool = False,
    label_count: int = 30,
) -> go.Figure:
    if graph.number_of_nodes() == 0:
        fig = go.Figure()
        fig.add_annotation(text="No nodes passed the current filter.", showarrow=False)
        fig.update_layout(title=title)
        return fig
    layout_name = str(layout_name).lower().replace("-", "_")
    if layout_name == "kamada_kawai":
        layout = nx.kamada_kawai_layout(graph, weight="weight")
    elif layout_name == "circular":
        layout = nx.circular_layout(graph)
    else:
        layout = nx.spring_layout(graph, seed=42, weight="weight", k=None)
    edge_x: list[float | None] = []
    edge_y: list[float | None] = []
    for source, target in graph.edges():
        x0, y0 = layout[source]
        x1, y1 = layout[target]
        edge_x.extend([x0, x1, None])
        edge_y.extend([y0, y1, None])
    edge_trace = go.Scatter(x=edge_x, y=edge_y, mode="lines", line={"width": 1.65, "color": "#52665b"}, hoverinfo="none", name="Connections", showlegend=False, meta={"bra_role": "edge"})
    grouped_nodes: dict[str, list[dict]] = defaultdict(list)
    top_nodes = set()
    if show_labels:
        top_nodes = {node for node, _ in sorted(graph.degree, key=lambda item: item[1], reverse=True)[: max(1, label_count)]}
    for node, attrs in graph.nodes(data=True):
        x, y = layout[node]
        degree = graph.degree(node)
        label = str(attrs.get("label", node))
        explicit_group = attrs.get("kind", attrs.get("module", ""))
        group = "" if pd.isna(explicit_group) else str(explicit_group).strip()
        if not group or group.casefold() in {"nan", "none", "node"}:
            if directed and isinstance(graph, nx.DiGraph):
                group = "Regulator" if graph.out_degree(node) > 0 else "Target"
            else:
                group = "Network node"
        lowered = group.casefold()
        if lowered == "gene": legend_name = "Gene"
        elif lowered == "term": legend_name = "GO / pathway term"
        elif lowered in {"regulator", "target", "network node"}: legend_name = group
        elif lowered.startswith("module"): legend_name = group
        else: legend_name = f"Module {group}"
        grouped_nodes[legend_name].append({
            "x": float(x), "y": float(y), "label": label,
            "display": label if node in top_nodes else "",
            "hover": f"{label}<br>Degree {degree}<br>Node color: {legend_name}",
            "size": min(32, 8 + 2.2 * math.sqrt(max(degree, 1))),
            "custom": ["BRA_SELECTION", str(attrs.get("term_id", node if lowered == "term" else "")), label, str(attrs.get("genes", node if lowered == "gene" else ""))],
        })
    palette = ["#75bed1", "#dc7f8c", "#edb458", "#8b78bd", "#65b891", "#e98957", "#6f91c9", "#c48ec7", "#9aae61", "#d46b60", "#65a6a3", "#a58b6f"]
    node_traces: list[go.Scatter] = []
    for group_index, (legend_name, records) in enumerate(grouped_nodes.items()):
        module_raw = legend_name[len("Module "):].strip() if legend_name.startswith("Module ") else ""
        node_traces.append(go.Scatter(
            x=[record["x"] for record in records],
            y=[record["y"] for record in records],
            mode="markers+text" if show_labels else "markers",
            marker={"size": [record["size"] for record in records], "color": palette[group_index % len(palette)], "line": {"width": 0.65, "color": "rgba(30,45,36,.65)"}},
            text=[record["display"] for record in records] if show_labels else None,
            textposition="top center",
            hovertext=[record["hover"] for record in records],
            hoverinfo="text",
            customdata=[record["custom"] for record in records],
            name=legend_name,
            legendgroup=legend_name,
            showlegend=True,
            meta={"bra_role": "node", "bra_group": legend_name, "bra_module_raw": module_raw},
        ))
    fig = go.Figure(data=[edge_trace, *node_traces])
    annotations: list[dict] = [{"text": "Directed" if directed else "Undirected", "xref": "paper", "yref": "paper", "x": 0.01, "y": 0.01, "showarrow": False}]
    if directed:
        for source, target in graph.edges():
            x0, y0 = layout[source]
            x1, y1 = layout[target]
            annotations.append({"x": float(x1), "y": float(y1), "ax": float(x0), "ay": float(y0), "xref": "x", "yref": "y", "axref": "x", "ayref": "y", "showarrow": True, "arrowhead": 2, "arrowsize": 0.8, "arrowwidth": 1.35, "arrowcolor": "#52665b", "opacity": 0.88, "text": ""})
    fig.update_layout(title=title, meta={"bra_kind": "network"}, showlegend=True, legend={"title": {"text": "Node color"}, "x": 1.01, "xanchor": "left", "y": 1.0, "yanchor": "top", "bgcolor": "rgba(255,255,255,.88)"}, margin={"l": 40, "r": 180, "t": 45, "b": 45}, xaxis={"visible": False, "showgrid": False, "zeroline": False}, yaxis={"visible": False, "showgrid": False, "zeroline": False}, dragmode="pan", annotations=annotations)
    return fig


def network_plots(config: dict) -> list[str]:
    output_dir = Path(config["output_dir"])
    selected = plot_selection(config, {"gene_network", "module_trait", "eigengenes"})
    created: list[str] = []

    if "gene_network" in selected:
        edge_path = config.get("edge_file") or str(output_dir / "network_edges.tsv")
        node_path = config.get("node_file") or str(output_dir / "network_nodes.tsv")
        edges = read_table(edge_path)
        nodes = read_table(node_path) if os.path.exists(node_path) else pd.DataFrame()
        source_col = first_existing(edges, ["source", "regulator", "from"])
        target_col = first_existing(edges, ["target", "gene", "to"])
        weight_col = first_existing(edges, ["weight", "correlation", "importance"])
        if not source_col or not target_col:
            raise ValueError("The edge table must contain source and target columns.")
        if not weight_col:
            edges["weight"] = 1.0
            weight_col = "weight"
        edges[weight_col] = pd.to_numeric(edges[weight_col], errors="coerce").fillna(0.0)
        edges = edges.reindex(edges[weight_col].abs().sort_values(ascending=False).index).head(int(config.get("max_plot_edges", 500)))
        directed = bool(config.get("directed", False)) or str(config.get("method", "")).upper() == "GENIE3"
        graph: nx.Graph = nx.DiGraph() if directed else nx.Graph()
        node_attrs: dict[str, dict] = {}
        # A method can legitimately complete with zero edges/modules (for
        # example CEMiTool on a very small exploratory dataset). Do not run a
        # spring layout over thousands of unconnected genes; show an explicit
        # diagnostic placeholder instead.
        if edges.empty:
            fig = go.Figure()
            fig.add_annotation(
                text="No co-expression edges/modules were detected for the selected settings. See the network summary and method diagnostics.",
                showarrow=False,
                x=0.5,
                y=0.5,
                xref="paper",
                yref="paper",
            )
            fig.update_layout(title="Interactive gene network", xaxis={"visible": False}, yaxis={"visible": False})
        else:
            if not nodes.empty:
                node_id_col = first_existing(nodes, ["gene_id", "node", "id"]) or nodes.columns[0]
                for _, row in nodes.iterrows():
                    node = str(row[node_id_col])
                    node_attrs[node] = {key: row[key] for key in nodes.columns if key != node_id_col}
                    display_label = str(node_attrs[node].pop("label", "") or node)
                    graph.add_node(node, label=display_label, **node_attrs[node])
            for _, row in edges.iterrows():
                source = str(row[source_col])
                target = str(row[target_col])
                if source not in graph:
                    graph.add_node(source, label=source, **node_attrs.get(source, {}))
                if target not in graph:
                    graph.add_node(target, label=target, **node_attrs.get(target, {}))
                graph.add_edge(source, target, weight=float(abs(row[weight_col])))
            fig = network_figure_from_graph(
                graph,
                directed=directed,
                title="Interactive gene network",
                layout_name=str(config.get("graph_layout", "spring")),
                show_labels=bool(config.get("show_node_labels", False)),
                label_count=int(config.get("node_label_count", 30)),
            )
        write_plot(fig, output_dir / "gene_network_interactive.html")
        created.append("gene_network_interactive.html")

    module_trait_path = output_dir / "module_trait_associations.tsv"
    if "module_trait" in selected and module_trait_path.exists():
        mt = read_table(str(module_trait_path))
        if {"module", "trait", "correlation"}.issubset(mt.columns) and not mt.empty:
            pivot = mt.pivot(index="module", columns="trait", values="correlation")
            module_values = pivot.index.astype(str).tolist()
            module_hover = np.repeat(np.asarray(module_values, dtype=object)[:, None], len(pivot.columns), axis=1)
            fig = go.Figure(data=go.Heatmap(z=pivot.to_numpy(), x=pivot.columns.astype(str), y=module_values, customdata=module_hover, zmid=0, colorbar={"title": "Correlation"}, hovertemplate="<b>%{customdata}</b><br>Trait %{x}<br>r %{z:.3f}<extra></extra>"))
            fig.update_xaxes(showgrid=False, zeroline=False)
            fig.update_yaxes(showgrid=False, zeroline=False, tickmode="array", tickvals=module_values, ticktext=module_values)
            fig.update_layout(title="Module–trait associations", meta={"bra_module_axes": [{"axis": "yaxis", "values": module_values}]})
            write_plot(fig, output_dir / "module_trait_interactive.html")
            created.append("module_trait_interactive.html")

    eigengene_path = output_dir / "module_eigengenes.tsv"
    if "eigengenes" in selected and eigengene_path.exists():
        eig = read_table(str(eigengene_path))
        sample_col = eig.columns[0]
        if len(eig.columns) >= 2:
            long = eig.melt(id_vars=sample_col, var_name="module", value_name="eigengene")
            fig = px.line(long, x=sample_col, y="eigengene", color="module", markers=True, title="Module eigengenes across samples")
            for trace in fig.data:
                trace.meta = {"bra_module_raw": str(trace.name)}
            write_plot(fig, output_dir / "module_eigengenes_interactive.html")
            created.append("module_eigengenes_interactive.html")
    created.extend(network_module_expression_plots(config, output_dir))
    return list(dict.fromkeys(created))


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: interactive_plots.py MODE CONFIG.json", file=sys.stderr)
        return 2
    mode = sys.argv[1].lower()
    config = load_config(sys.argv[2])
    if mode == "de":
        created = de_plots(config)
    elif mode == "circular":
        created = [circular_plot(config)]
    elif mode in {"gene-range", "gene_range"}:
        created = [gene_range_plot(config)]
    elif mode == "enrichment":
        created = enrichment_plots(config)
    elif mode == "network":
        created = network_plots(config)
    else:
        raise ValueError(f"Unknown plotting mode: {mode}")
    for item in created:
        print(f"PLOT\t{item}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
