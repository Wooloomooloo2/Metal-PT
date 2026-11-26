// The site's one stylesheet and its small optional script, served by the Worker (/static/site.css, /static/site.js).
// Look per the approved mockups: #F6F7F9 ground, #14161A text, #5A6170 muted, #2457D6 accent, #B23A0A FPS/W;
// Inter / Space Grotesk / JetBrains Mono. Works at 360 px: rows wrap, wide tables scroll inside their own box.

/** Bump when either file changes (the URLs carry it, so long browser caching is safe). */
export const STATIC_VERSION = "1";

export const SITE_CSS = `
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:#F6F7F9;color:#14161A;font-family:Inter,system-ui,-apple-system,sans-serif;font-size:16px;line-height:1.45}
a{color:#2457D6}a:hover{color:#173E9E}
h1,h2,h3{font-family:'Space Grotesk',Inter,sans-serif;margin:0;overflow-wrap:anywhere}
h1{font-size:40px;line-height:1.1;font-weight:700}
h1.run{font-size:34px;line-height:1.15}
h2{font-size:20px;font-weight:600}
h3{font-size:18px;font-weight:600}
p{margin:0}
.num{font-family:'JetBrains Mono',ui-monospace,monospace;font-variant-numeric:tabular-nums}
.muted{color:#5A6170}
.small{font-size:14px}
.tiny{font-size:13px}
.fpw{color:#B23A0A}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.wrap{max-width:1200px;margin:0 auto;padding-left:20px;padding-right:20px}

.site-head{background:#FFFFFF;border-bottom:1px solid #E4E7EC}
.site-head .wrap{padding-top:14px;padding-bottom:14px;display:flex;flex-wrap:wrap;align-items:center;gap:12px 28px}
.brand{font-family:'Space Grotesk',sans-serif;font-weight:700;font-size:22px;color:#14161A;text-decoration:none}
.nav{display:flex;flex-wrap:wrap;gap:4px 20px;font-size:15px;font-weight:500}
.nav a{color:#5A6170;text-decoration:none}
.nav a[aria-current="page"]{color:#14161A}
.head-search{flex:1 1 220px;display:flex;justify-content:flex-end}
input[type=search]{width:100%;max-width:320px;height:40px;border:1px solid #D0D5DD;border-radius:8px;padding:0 12px;font:inherit;font-size:15px;background:#F6F7F9;color:#14161A}

main.wrap{padding-top:32px;padding-bottom:56px;display:flex;flex-direction:column;gap:24px}
.site-foot{border-top:1px solid #E4E7EC;background:#FFFFFF}
.site-foot .wrap{padding-top:18px;padding-bottom:24px;display:flex;flex-wrap:wrap;gap:8px 20px;font-size:14px;color:#5A6170}

.page-head{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-end;gap:16px}
.page-head.top{align-items:flex-start}
.stack{display:flex;flex-direction:column;gap:6px;min-width:0}
.stack.gap8{gap:8px}
.card{background:#FFFFFF;border:1px solid #E4E7EC;border-radius:12px}
.card.pad{padding:18px 20px}
.card.clip{overflow:hidden}
.card-head{padding:16px 20px;display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;align-items:baseline}
.card-foot{padding:14px 20px;border-top:1px solid #E4E7EC;display:flex;flex-wrap:wrap;gap:8px 20px;font-size:14px;color:#5A6170}
.empty{padding:16px 20px 20px;color:#5A6170}

.pickers{padding:16px 20px;display:flex;flex-wrap:wrap;gap:16px 28px;align-items:flex-end}
.field{display:flex;flex-direction:column;gap:6px;min-width:0;border:0;padding:0;margin:0}
.label{font-size:12px;font-weight:600;color:#5A6170;text-transform:uppercase;letter-spacing:.04em;padding:0}
select{height:40px;min-width:140px;max-width:100%;border:1px solid #D0D5DD;border-radius:8px;padding:0 10px;font:inherit;background:#FFFFFF;color:#14161A}
.seg{display:flex;border:1px solid #D0D5DD;border-radius:8px;overflow:hidden}
.seg label{position:relative}
.seg input{position:absolute;opacity:0;inset:0;margin:0}
.seg span{display:inline-flex;align-items:center;height:38px;padding:0 16px;background:#FFFFFF;color:#14161A;font-weight:500;cursor:pointer}
.seg input:checked+span{background:#14161A;color:#FFFFFF}
.seg input:focus-visible+span{outline:2px solid #2457D6;outline-offset:-2px}

.btn{height:44px;display:inline-flex;align-items:center;padding:0 18px;border:1px solid #D0D5DD;background:#FFFFFF;border-radius:8px;font:inherit;font-weight:500;color:#14161A;text-decoration:none;cursor:pointer}
.btn:hover{color:#14161A;border-color:#98A2B3}
.btn.primary{background:#2457D6;border-color:#2457D6;color:#FFFFFF}
.btn.primary:hover{background:#173E9E;color:#FFFFFF}
.btn.small{height:40px}
.actions{display:flex;flex-wrap:wrap;gap:10px}

.table-box{overflow-x:auto;-webkit-overflow-scrolling:touch}
table.data{width:100%;border-collapse:collapse;font-size:15px}
table.data.wide{min-width:860px}
table.data.mid{min-width:720px}
table.data.narrow{min-width:560px}
.data th{font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:#5A6170;padding:10px 12px;text-align:left;white-space:nowrap}
.data th .unit{font-weight:500;text-transform:none;letter-spacing:0}
.data th a{color:inherit}
.data td{padding:14px 12px;border-top:1px solid #E4E7EC;vertical-align:middle}
.data th:first-child,.data td:first-child{padding-left:20px}
.data th:last-child,.data td:last-child{padding-right:20px}
.data .nw{white-space:nowrap}
.data .big{font-size:20px}
.data .sub{font-size:13px;color:#5A6170;font-weight:400}
.data .strong{font-weight:600}
.data tr.diff{background:#FFFBEB}
.data td.diff{font-weight:600}
.data td.note{color:#5A6170;font-size:14px}

.range{display:flex;align-items:center;gap:10px;min-width:200px}
.range .bar{position:relative;flex:1;height:10px;background:#EEF1F5;border-radius:5px}
.range .mid{position:absolute;top:0;bottom:0;background:#AFC4F5;border-radius:5px;min-width:4px}
.range .typ{position:absolute;width:3px;top:-4px;bottom:-4px;background:#2457D6;border-radius:2px;margin-left:-1px}
.tag{display:inline-block;font-family:Inter,sans-serif;font-size:12px;font-weight:600;border-radius:999px;padding:2px 8px;background:#EEF1F5;color:#5A6170;white-space:nowrap}
.tag.cap{background:#FFF4E0;color:#8A4B00}
.tag.base{background:#EAF0FD;color:#2457D6;margin-left:4px}

.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(260px,100%),1fr));gap:12px}
.run-card{text-decoration:none;color:inherit;background:#FFFFFF;border:1px solid #E4E7EC;border-radius:12px;padding:16px;display:flex;flex-direction:column;gap:6px;min-width:0}
.run-card:hover{color:inherit;border-color:#98A2B3}
.run-card .t{font-weight:600;overflow-wrap:anywhere}
.counts{display:flex;flex-wrap:wrap;gap:12px}
.count{flex:1 1 140px}

.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{font-size:13px;font-weight:500;background:#EEF1F5;border-radius:999px;padding:5px 12px}
.chip.ok{background:#E7F5EC;color:#11613A}
.chip.warn{background:#FFF4E0;color:#8A4B00}
a.chip-link{text-decoration:none;font-size:14px;font-weight:500;color:#14161A;border:1px solid #D0D5DD;background:#FFFFFF;border-radius:999px;padding:8px 14px}
a.chip-link[aria-current="page"]{color:#FFFFFF;border-color:#14161A;background:#14161A}

.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(200px,100%),1fr));gap:12px}
.tile{background:#FFFFFF;border:1px solid #E4E7EC;border-radius:12px;padding:18px;display:flex;flex-direction:column;gap:4px;min-width:0}
.tile .k{font-size:13px;font-weight:600;color:#5A6170}
.tile .v{font-size:36px;line-height:1.2}
.tile .w{font-family:'Space Grotesk',sans-serif;font-size:26px;font-weight:600;line-height:1.3}
.tile .d{font-size:13px;color:#5A6170}
.tile.power{background:#FFF7F2;border-color:#F3CDB8}
.tile.power .k,.tile.power .v{color:#B23A0A}

.chart-card{display:flex;flex-direction:column;gap:12px}
svg.chart{width:100%;height:220px;display:block}
.ticks{position:relative;height:18px;font-size:12px;color:#5A6170}
.ticks span{position:absolute;top:0;transform:translateX(-50%);white-space:nowrap}
.ticks span:first-child{transform:none}
.ticks span:last-child{transform:translateX(-100%)}

.details{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(320px,100%),1fr));gap:12px}
.kv{display:flex;flex-direction:column;gap:10px;font-size:15px}
.kv .row{display:flex;justify-content:space-between;gap:12px}
.kv .row>span:first-child{color:#5A6170}
.kv .row>span:last-child{text-align:right;overflow-wrap:anywhere}
.prose{line-height:1.5;white-space:pre-wrap;overflow-wrap:anywhere}

.video{display:flex;gap:14px;align-items:center;text-decoration:none;color:inherit}
.video .play{flex:none;width:56px;height:40px;border-radius:10px;background:#14161A;display:flex;align-items:center;justify-content:center}
.video .play::after{content:"";border-left:14px solid #FFFFFF;border-top:9px solid transparent;border-bottom:9px solid transparent;margin-left:3px}

.verdict{background:#14161A;color:#FFFFFF;border-radius:12px;padding:20px 24px;display:flex;flex-direction:column;gap:8px}
.verdict .s{font-size:20px;line-height:1.4;font-family:'Space Grotesk',sans-serif;font-weight:500}
.verdict .hi{color:#FFB089}
.verdict .n{font-size:14px;color:#C4C9D2}
.verdict .warn{font-size:14px;color:#FFD38A}

.bars{padding:8px 20px 16px;display:flex;flex-direction:column}
.bar-row{display:flex;flex-wrap:wrap;align-items:center;gap:12px 24px;padding:16px 0;border-bottom:1px solid #E4E7EC}
.bar-row .who{flex:1 1 240px;display:flex;flex-direction:column;gap:2px;min-width:0}
.bar-row .who .t{font-weight:600;overflow-wrap:anywhere}
.bar-row .meters{flex:3 1 300px;display:flex;flex-direction:column;gap:6px;min-width:0}
.meter{display:flex;align-items:center;gap:10px}
.meter .track{flex:1;height:14px;background:#EEF1F5;border-radius:4px}
.meter .fill{height:100%;background:#2457D6;border-radius:4px}
.meter .fill.w{background:#E06A2E}
.meter .val{width:84px;text-align:right;flex:none}
.legend{display:flex;flex-wrap:wrap;gap:8px 20px;font-size:13px;color:#5A6170;padding-top:12px}
.legend span{display:inline-flex;align-items:center;gap:6px}
.legend i{width:12px;height:12px;border-radius:3px;background:#2457D6;display:inline-block}
.legend i.w{background:#E06A2E}

details summary{cursor:pointer;color:#2457D6}
.list{list-style:none;margin:0;padding:0}
.list li{padding:12px 20px;border-top:1px solid #E4E7EC;display:flex;flex-wrap:wrap;gap:4px 16px;justify-content:space-between;align-items:baseline}
.list li .t{font-weight:600;overflow-wrap:anywhere}
.privacy{max-width:760px;display:flex;flex-direction:column;gap:18px}
.privacy ul{margin:0;padding-left:22px;display:flex;flex-direction:column;gap:6px}

@media (max-width:600px){
  .wrap{padding-left:16px;padding-right:16px}
  main.wrap{padding-top:24px}
  h1{font-size:30px}
  h1.run{font-size:26px}
  .tile .v{font-size:30px}
  .card-head,.card-foot,.pickers{padding-left:16px;padding-right:16px}
  .data th:first-child,.data td:first-child{padding-left:16px}
  .data th:last-child,.data td:last-child{padding-right:16px}
  .bars{padding-left:16px;padding-right:16px}
  .list li{padding-left:16px;padding-right:16px}
  .verdict{padding:18px 16px}
  .head-search{justify-content:stretch}
  input[type=search]{max-width:none}
  select{min-width:0;width:100%}
  .pickers .field{flex:1 1 140px}
}
`;

/** Optional: "Copy link" copies instead of navigating. Without it the button is a plain link to the page. */
export const SITE_JS = `
document.addEventListener("click", function (e) {
  var a = e.target.closest && e.target.closest("[data-copy]");
  if (!a || !navigator.clipboard) return;
  e.preventDefault();
  navigator.clipboard.writeText(a.href).then(function () {
    var t = a.textContent; a.textContent = "Link copied";
    setTimeout(function () { a.textContent = t; }, 1600);
  });
});
document.addEventListener("change", function (e) {
  var f = e.target.form;
  if (f && f.hasAttribute("data-autosubmit")) f.submit();
});
`;
