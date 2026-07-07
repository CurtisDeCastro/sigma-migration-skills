import { convertPowerBIToSigma } from "/Users/tjwells/sigma-data-model-mcp/build/powerbi.js";
import fs from "fs";
const bim = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = convertPowerBIToSigma(bim, { connectionId: process.argv[3]||"", database: process.argv[4]||"", schema: process.argv[5]||"" });
fs.writeFileSync(process.argv[6], JSON.stringify(out, null, 2));
const m = out.model || out;
console.log("keys:", Object.keys(out).join(","));
console.log("warnings:", (out.warnings||[]).length);
const els = (m.elements||[]);
console.log("elements:", els.length);
for (const e of els.slice(0,8)) {
  console.log(` - ${e.elementType||e.type||"?"} name=${e.name} source=${JSON.stringify(e.source||e.sources||{}).slice(0,120)}`);
}
