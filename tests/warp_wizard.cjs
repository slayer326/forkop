const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createEnvironment } = require('./helpers/luci_form_harness.js');
const source = fs.readFileSync(path.join(__dirname, '../luci-app-forkop/htdocs/luci-static/resources/view/forkop/warp.js'), 'utf8');
const nodes = [], calls = [];
function E(tag, attrs, children) {
  const node = { tag, attrs:attrs || {}, children:children || [], style:{}, value:attrs?.value || '', checked:false, disabled:false, textContent:'' };
  if (tag === 'select') node.value = children[0].value;
  nodes.push(node);
  return node;
}
let action = '', created = '', requestedName = '';
const rpc = { declare(spec) { return async (...args) => {
  calls.push([spec.method, ...args]);
  if (spec.method === 'capabilities') return { success:true, wireguard:true, amneziawg:false, package_manager:'apk' };
  if (spec.method === 'start') {
    [action, , requestedName] = args;
    return { success:true, job_id:'1-2-3' };
  }
  if (spec.method === 'job') return action === 'generate' ? { success:true, profile:'PRIVATE_PROFILE_FIXTURE' } : { success:true, interface:requestedName };
  if (spec.method === 'status')
    return args[0] === created ? { success:true, handshake_observed:false } : { success:false, code:'interface_not_managed' };
  return { success:true };
}; } };
const wizard = new Function('baseclass', 'rpc', 'ui', 'E', '_', 'setTimeout', source)(
  { extend:value => value }, rpc, { showModal() {}, hideModal() {} }, E, value => value, callback => callback(),
);
const button = label => nodes.find(n => n.tag==='button' && n.children===label);
(async () => {
  wizard.open(name => { created=name; });
  const inputFile=nodes.find(n=>n.tag==='input' && n.attrs.type==='file');
  inputFile.files=[{size:20,text:async()=>'IMPORTED_FILE_FIXTURE'}];
  await inputFile.attrs.change.call(inputFile);
  assert.equal(nodes.find(n=>n.tag==='textarea').value,'IMPORTED_FILE_FIXTURE');
  await button('Generate WARP profile').attrs.click();
  assert.equal(calls.some(c => c[0]==='start'), false, 'registration requires explicit terms acceptance');
  const checks=nodes.filter(n=>n.tag==='input' && n.attrs.type==='checkbox');
  const interfaceName=nodes.find(n=>n.tag==='input' && n.attrs.type==='text');
  const status=nodes.find(n=>n.attrs.role==='status');
  interfaceName.value='WARPs';
  checks[2].checked=true;
  await button('Generate WARP profile').attrs.click();
  assert.equal(nodes.find(n=>n.tag==='textarea').value, 'PRIVATE_PROFILE_FIXTURE');
  await button('Check handshake').attrs.click();
  assert.equal(status.textContent,'Create the interface first, or enter the name of an existing Forkop WARP interface.');
  assert.equal(calls.find(c=>c[0]==='status')[1],'fkwwarps');
  for (const invalidName of ['fkw', 'warp-1', '12345678901']) {
    interfaceName.value=invalidName;
    await button('Create and add to section').attrs.click();
    assert.match(status.textContent,/prefix is added automatically/);
  }
  assert.equal(calls.some(c=>c[0]==='start' && c[1]==='import'),false,'invalid names do not reach RPC');
  interfaceName.value='WARPs';
  await button('Create and add to section').attrs.click();
  assert.equal(created,'fkwwarps');
  assert.equal(interfaceName.value,created,'the field shows the actual interface name');
  const imported=calls.find(c=>c[0]==='start' && c[1]==='import');
  assert.equal(imported[3],'fkwwarps');
  assert.equal(imported[4], 'PRIVATE_PROFILE_FIXTURE');
  assert.equal(imported[5], false, 'IPv6 is opt in');
  assert.equal(calls.filter(c=>c[0]==='ack').length,2,'private job results are acknowledged');
  await button('Check handshake').attrs.click();
  assert.match(status.textContent,/No handshake observed yet/);
  assert.equal(calls.filter(c=>c[0]==='status').at(-1)[1],created,'the prefix is not added twice');
  await button('Close').attrs.click();
  assert.equal(nodes.find(n=>n.tag==='textarea').value,'','closing clears the profile');
  for (const version of ['24.10', '25.12']) for (const discoveryFailure of [false,true]) {
    let attach;
    const env=createEnvironment({ version, config:{ main:{'.name':'main','.type':'section',action:'connection',enabled:'1'} }, warp:{ open(callback) { attach=callback; } }, network:{flushCache:async()=>{if(discoveryFailure) throw new Error('temporary RPC failure');}} });
    const rule=await env.openRule('main');
    const widget=rule.option('interfaces').getUIElement('main');
    widget.node=env.document.createElement('div');
    widget.options={};
    widget.addItem=(_node,value)=>widget.setValue([...widget.getValue(),value]);
    widget.dispatchCbiDynlistChange=()=>{};
    rule.option('_warp_wizard').renderWidget('main').attrs.click();
    await attach('fkwtest');
    assert.equal(rule.option('interfaces').validate('main','fkwtest'),true,'new interface validates before device discovery');
    assert.deepEqual(widget.getValue(),['fkwtest']);
    await rule.save();
    assert.equal(env.uci.sections('forkop','section_interface')[0].name,'fkwtest');
    const readonly=await env.openRule('main',{readonly:true});
    assert.equal(readonly.option('_warp_wizard').renderWidget('main').attrs.disabled,true);
  }
  console.log('WARP wizard registration, import and cleanup passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
