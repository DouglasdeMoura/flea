// Run with node tests/menu-dialog-check.js; exercise the QML reply handler against real asynchronous orderings.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../ui/MenuActionDialog.qml'), 'utf8');
const receive = source.match(/^    function receive\(message\) \{([\s\S]*?)^    \}/m);
assert.ok(receive, 'the production reply handler must be present');

function dialog() {
    const events = [];
    const state = {opened: false, action: 'deletePermanently', committing: true, busy: true, requestId: 3,
        facts: {count: 2}, checkPending: false, errorText: '', confirmation: {close() { events.push('hide'); }, open() { events.push('show'); }},
        closeFocus: {forceActiveFocus() { events.push('focus-cancel'); }},
        refreshDeletion() { events.push('refresh'); }, checkDeletion() { events.push('check'); },
        deleted(message) { events.push(message); }, finish() { events.push('finish'); }, events};
    Object.defineProperty(state, 'deletionActive', {get() { return this.action === 'deletePermanently' && this.committing; }});
    vm.createContext(state);
    vm.runInContext('function receive(message) {' + receive[1] + '\n}', state);
    return state;
}

const deleting = dialog();
deleting.receive({id: 3, op: 'checkDelete', ok: true, valid: true});
assert.equal(deleting.committing, true, 'an earlier check reply cannot clear the active delete');
deleting.receive({id: 3, op: 'delete', ok: true, deleted: 1, failed: 1, remaining: ['/fixture/survivor']});
assert.equal(deleting.events[0].count, 2);
assert.equal(deleting.events[0].deleted, 1);
assert.equal(deleting.events[1], 'finish');

const stale = dialog();
stale.receive({id: 3, op: 'delete', ok: true, stale: true});
assert.deepEqual(stale.events, ['refresh'], 'stale identities require a fresh confirmation before mutation');

const failed = dialog();
failed.receive({id: 3, op: 'delete', ok: false, error: 'backend stopped'});
assert.equal(failed.opened, true);
assert.equal(failed.committing, false);
assert.equal(failed.errorText, 'backend stopped');
assert.deepEqual(failed.events, ['hide', 'focus-cancel']);

const cancelled = dialog();
cancelled.committing = false;
cancelled.receive({id: 3, op: 'prepareDelete', ok: true, token: 19});
assert.deepEqual(cancelled.events, [], 'closing before preparation finishes cannot reopen the strip');
const changedWhileChecking = dialog();
changedWhileChecking.opened = true;
changedWhileChecking.committing = false;
changedWhileChecking.checkPending = true;
changedWhileChecking.receive({id: 3, op: 'checkDelete', ok: true, valid: true});
assert.deepEqual(changedWhileChecking.events, ['refresh'], 'a hidden stale strip must be replaced after a pending filesystem change');
const newer = dialog();
newer.receive({id: 2, op: 'delete', ok: false, error: 'old operation'});
assert.equal(newer.committing, true);
assert.deepEqual(newer.events, []);
console.log('menu dialog: 14 checks, 0 failed');
