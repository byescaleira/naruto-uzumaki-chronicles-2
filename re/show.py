import json,sys
for r in json.load(open(sys.argv[1])):
    if r['tool'] in ('open_binary',): continue
    res=r['result']
    v=res.get('raw_result',res) if isinstance(res,dict) else res
    if isinstance(v,dict) and 'value' in v: v=v['value']
    print('=====',r['tool'],json.dumps(r['args']),'ERR' if r['isError'] else '')
    print(v if isinstance(v,str) else json.dumps(v)[:int(sys.argv[2]) if len(sys.argv)>2 else 4000])
