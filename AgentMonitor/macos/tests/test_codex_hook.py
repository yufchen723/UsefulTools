import importlib.util
import json
import pathlib
import tempfile
from concurrent.futures import ThreadPoolExecutor

spec = importlib.util.spec_from_file_location('hook', pathlib.Path(__file__).parents[1] / 'hooks/claude-monitor-hook.py')
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
with tempfile.TemporaryDirectory() as directory:
    def send(name, tool='a', turn='t1'):
        hook.codex_event(dict(session_id='fixture', turn_id=turn, hook_event_name=name,
                             tool_name='Bash', tool_input={'command': tool}, cwd='/tmp'), directory)
    def state():
        return json.loads((pathlib.Path(directory) / 'fixture.json').read_text())
    send('UserPromptSubmit')
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda tool: send('PermissionRequest', tool), ['a', 'b', 'c', 'd']))
    assert state()['state'] == 'permission' and len(state()['pendingApprovals']) == 4
    send('PostToolUse', 'a'); send('PreToolUse', 'unrelated'); send('SubagentStop')
    assert state()['state'] == 'permission' and len(state()['pendingApprovals']) == 3
    for tool in ['b','c','d']: send('PostToolUse', tool)
    assert state()['state'] == 'running' and not state()['pendingApprovals']
    hook.codex_event(dict(session_id='fixture', turn_id='t1', hook_event_name='PermissionRequest',
                          tool_name='Bash', tool_input={'command':'description-test', 'description':'Reason for approval'}), directory)
    send('PostToolUse', 'description-test'); assert state()['state'] == 'running'
    send('PermissionRequest'); send('PermissionRequest'); send('PostToolUse')
    assert state()['state'] == 'permission'
    send('PostToolUse'); assert state()['state'] == 'running'
    send('PermissionRequest'); send('Interrupt'); assert state()['state'] == 'done'
    send('UserPromptSubmit', turn='t2'); send('PermissionRequest', turn='t2')
    send('PostToolUse', turn='t1'); assert state()['state'] == 'permission' and state()['turnId'] == 't2'
    send('Stop', turn='t2'); assert state()['state'] == 'done' and not state()['pendingApprovals']
print('PASS: parallel approvals, independent completions, identical calls, interruption, new turn and delayed old callbacks')
