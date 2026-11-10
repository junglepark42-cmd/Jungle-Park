const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(require.resolve('../index.html'),'utf8');
const calculations=html.slice(html.indexOf('function cpAdjustmentValue('),html.indexOf('function cpPos('));
const adjustment=html.slice(html.indexOf('var EDIT_CP_EMP_ID = null;'),html.indexOf('function pinPress('));
// Exercise the employee hydration used by login and refresh, not a separate test mapping.
const loadStart=html.indexOf('    var emps = await supaGet("employes"',html.indexOf('async function loadAllData()'));
const hydration='async function reloadEmployees(){'+html.slice(loadStart,html.indexOf('    // Conges',loadStart))+'}';
class FixedDate extends Date{constructor(...args){super(...(args.length?args:['2026-11-10T12:00:00Z']));}}
function setup(row={}){
  let stored={id:'person',nom:'Salariée test',contract:'Alternance',since:'2025-12-01',cp_ajust:0,...row};
  const controls={cpAjustTitle:{},cpAjustVal:{value:''},cpAjustNote:{value:''},cpAjustSave:{disabled:false}};
  const calls={messages:[],closed:[],logs:[],writes:[],renders:0};
  const c=vm.createContext({Date:FixedDate,EMP:{},CU:{role:'gerant'},CEID:null,
    document:{getElementById:id=>controls[id]||null},
    openModal:()=>{},closeModal:id=>calls.closed.push(id),showToast:msg=>calls.messages.push(msg),
    logActivity:(...args)=>calls.logs.push(args),renderHConges:()=>calls.renders++,
    supaGet:async()=>[stored],supaPatch:async(table,body,filter)=>{calls.writes.push({table,body,filter});stored={...stored,...body};return [stored];}
  });
  vm.runInContext(calculations+adjustment+hydration,c);
  return {c,controls,calls,stored:()=>stored};
}
test('zero total survives saving, actual employee reload and reopening the form',async()=>{
  const {c,controls,calls,stored}=setup();await c.reloadEmployees();
  c.openCPAjust('person');assert.equal(controls.cpAjustVal.value,27.5);
  controls.cpAjustVal.value='0';await c.saveCPAjust();
  assert.equal(stored().cp_ajust,-27.5);assert.equal(c.cpAcq(c.EMP.person),0);
  await c.reloadEmployees();assert.equal(c.EMP.person.cp_ajust,-27.5);assert.equal(c.cpAcq(c.EMP.person),0);
  c.openCPAjust('person');assert.equal(controls.cpAjustVal.value,0);
  assert.equal(calls.logs.length,1);assert.equal(calls.closed.length,1);assert.equal(controls.cpAjustSave.disabled,false);
});
test('numeric string adjustments add numerically and the form shows acquired total',async()=>{
  const {c,controls}=setup({cp_ajust:'-20'});await c.reloadEmployees();
  assert.equal(c.cpAcq(c.EMP.person),7.5);c.openCPAjust('person');assert.equal(controls.cpAjustVal.value,7.5);
  controls.cpAjustVal.value='7.5';await c.saveCPAjust();await c.reloadEmployees();assert.equal(c.cpAcq(c.EMP.person),7.5);
});
test('manual contract zero and half days persist through reload',async()=>{
  const {c,controls,stored}=setup({contract:'CDD',cp_ajust:9});await c.reloadEmployees();c.openCPAjust('person');
  controls.cpAjustVal.value='0';await c.saveCPAjust();await c.reloadEmployees();assert.equal(c.cpAcq(c.EMP.person),0);assert.equal(stored().cp_ajust,0);
  controls.cpAjustVal.value='4.5';await c.saveCPAjust();await c.reloadEmployees();assert.equal(c.cpAcq(c.EMP.person),4.5);
});
test('missing legacy adjustment is zero, without losing natural accrual',async()=>{
  const {c}=setup({cp_ajust:null});await c.reloadEmployees();assert.equal(c.EMP.person.cp_ajust,0);assert.equal(c.cpAcq(c.EMP.person),27.5);
});
test('empty input is not an intentional zero',async()=>{
  const {c,controls,calls}=setup();await c.reloadEmployees();c.openCPAjust('person');controls.cpAjustVal.value='';await c.saveCPAjust();
  assert.equal(calls.writes.length,0);assert.equal(calls.closed.length,0);assert.match(calls.messages.at(-1),/invalide/);
});
test('failed, empty or mismatched server responses never claim success or change the local balance',async()=>{
  for(const response of [null,[],true,[{id:'another',cp_ajust:-27.5}],[{id:'person',cp_ajust:null}],[{id:'person',cp_ajust:0}]]){
    const {c,controls,calls}=setup();await c.reloadEmployees();c.openCPAjust('person');controls.cpAjustVal.value='0';c.supaPatch=async()=>response;await c.saveCPAjust();
    assert.equal(c.EMP.person.cp_ajust,0);assert.equal(c.cpAcq(c.EMP.person),27.5);assert.equal(calls.logs.length,0);assert.equal(calls.closed.length,0);assert.match(calls.messages.at(-1),/non confirmé/);assert.equal(controls.cpAjustSave.disabled,false);
  }
});
test('network failure unlocks retry and retains the entered zero',async()=>{
  const {c,controls,calls}=setup();await c.reloadEmployees();c.openCPAjust('person');controls.cpAjustVal.value='0';c.supaPatch=async()=>{throw new Error('offline');};await c.saveCPAjust();
  assert.equal(controls.cpAjustVal.value,'0');assert.equal(c.CP_ADJUST_SAVING,false);assert.equal(calls.closed.length,0);assert.match(calls.messages.at(-1),/non enregistré/);
});
test('a double click sends a single update and cannot switch employee during save',async()=>{
  const {c,controls,calls}=setup();await c.reloadEmployees();c.openCPAjust('person');controls.cpAjustVal.value='0';
  let resolve,requests=0;c.supaPatch=()=>{requests++;return new Promise(r=>{resolve=r;});};
  const first=c.saveCPAjust();await c.saveCPAjust();c.openCPAjust('other');assert.equal(c.EDIT_CP_EMP_ID,'person');
  resolve([{id:'person',cp_ajust:'-27.5'}]);await first;assert.equal(requests,1);assert.equal(calls.logs.length,1);assert.equal(c.cpAcq(c.EMP.person),0);
});
