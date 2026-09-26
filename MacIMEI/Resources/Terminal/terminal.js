'use strict';
const term = new Terminal({fontFamily:'Menlo, monospace',fontSize:12,scrollback:3000,convertEol:false,cursorBlink:true,disableStdin:true,allowProposedApi:false,theme:{background:'#081528',foreground:'#EDF4FC',cursor:'#3EB6E2',selectionBackground:'#163B61'}});
const fit = new FitAddon.FitAddon();term.loadAddon(fit);term.open(document.getElementById('terminal'));
const post=(type,value)=>window.webkit.messageHandlers.terminal.postMessage({type,value});
term.onData(data=>post('input',data));term.onBinary(data=>post('binary',data));term.onResize(size=>post('resize',size));
// Modem escape sequences cannot read/write the Mac clipboard or set app titles.
term.parser.registerOscHandler(52,()=>true);
window.terminalWrite=b64=>{const raw=atob(b64);term.write(Uint8Array.from(raw,c=>c.charCodeAt(0)));};
window.terminalReset=()=>term.reset();
let terminalWasConnected=false;
window.terminalConnected=value=>{term.options.disableStdin=!value;if(value&&!terminalWasConnected){term.focus();}terminalWasConnected=value;};
window.terminalFocus=()=>term.focus();
new ResizeObserver(()=>{try{fit.fit();}catch{}}).observe(document.getElementById('terminal'));
fit.fit();post('ready',{cols:term.cols,rows:term.rows});
