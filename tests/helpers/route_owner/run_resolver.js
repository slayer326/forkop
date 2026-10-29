// Runs every route/owner case through routing/resolve.uc resolve() directly
// and prints { case: result } as JSON.
const fs = require('fs'), path = require('path'), { execFileSync } = require('child_process');
const [lib, work, casesFile] = process.argv.slice(2);
const cases = require(casesFile);
const config = fs.readFileSync(path.join(__dirname, 'forkop.uci'), 'utf8');
fs.writeFileSync(path.join(work, 'resolve.uc'), `let r = require("routing.resolve");
let sections = r.parse_config(require("fs").readfile(ARGV[0]));
let t = r.target(ARGV[2], "142.250.1.1", { fakeip: ARGV[3] == "1" });
print(sprintf("%J\\n", r.resolve(r.load_json(ARGV[1]), sections, t)));
`);
const out = {};
for (const [name, rules, opts = {}] of cases) {
  const dir = path.join(work, name); fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'forkop'), config);
  const singbox = path.join(dir, 'config.json');
  if (rules) fs.writeFileSync(singbox, JSON.stringify({ route: { final: 'direct-out', rules: rules.map((r) => JSON.parse(JSON.stringify(r))) },
    outbounds: [
      { type: 'direct', tag: 'direct-out' },
      { type: 'vless', tag: 'main-out' },
      { type: 'vless', tag: 'youtube-out' },
      { type: 'vless', tag: 'discord-out' },
    ] }));
  const fakeip = !(opts.dns && !opts.dns.startsWith('198.18.'));
  out[name] = JSON.parse(execFileSync('ucode', ['-L', lib, path.join(work, 'resolve.uc'), path.join(dir, 'forkop'), singbox,
    opts.host || 'www.youtube.com', fakeip ? '1' : '0'], { env: { ...process.env, FORKOP_LIB: lib } }).toString());
}
console.log(JSON.stringify(out, null, 1));
