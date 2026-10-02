#!/usr/bin/python3
import json, sys, time
from pathlib import Path
state = json.loads(Path(__file__).with_name('fake-account-state.json').read_text())
for line in sys.stdin:
    message = json.loads(line)
    if 'id' not in message:
        continue
    method = message.get('method')
    if method == 'initialize':
        result = {}
    elif method == 'account/read':
        result = {'account':state.get('account'),'requiresOpenaiAuth':True}
    elif method == 'account/rateLimits/read':
        time.sleep(0.12)
        if state.get('quotaError'):
            print(json.dumps({'id':message['id'],'error':{'code':-1,'message':'test failure'}}),flush=True)
            continue
        result = state['limits']
    else:
        continue
    print(json.dumps({'id':message['id'],'result':result}),flush=True)
