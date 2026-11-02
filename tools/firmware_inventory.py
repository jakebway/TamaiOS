import argparse, hashlib, json, pathlib, re, subprocess
p=argparse.ArgumentParser()
p.add_argument('--rom', required=True)
p.add_argument('--core', required=True)
p.add_argument('--out', default='analysis')
a=p.parse_args()
rom=pathlib.Path(a.rom); data=rom.read_bytes()
if len(data)!=0x800000: raise SystemExit('Expected an 8 MiB flash image')
blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
if blob!='b90fcfc2c43516c750b5e840c0132c35f20be4cd': raise SystemExit('Wonder Garden git blob identity mismatch: '+blob)
core=pathlib.Path(a.core)
commit=subprocess.check_output(['git','-C',str(core),'rev-parse','HEAD'],text=True).strip()
if commit!='41204c92e98a8882d5c90a9876d8990f3b63e285': raise SystemExit('Unexpected core revision')
out=pathlib.Path(a.out); out.mkdir(parents=True,exist_ok=True)
sigs=(core/'core/src/sigs.rs').read_text()
results=[]
for name,pattern in re.findall(r'pub const (\w+): &str\s*=\s*"([^"]+)";',sigs):
    compact=re.sub(r'\s+','',pattern)
    if len(compact)%2: raise ValueError(name)
    pairs=[compact[i:i+2] for i in range(0,len(compact),2)]
    expr=b''.join(b'.' if x=='??' else re.escape(bytes.fromhex(x)) for x in pairs)
    offsets=[m.start() for m in re.finditer(b'(?=('+expr+b'))',data[:0x220000],re.DOTALL)]
    results.append({'signature':name,'matches':[{'offset':hex(i),'address':hex(0x20000000+i)} for i in offsets], 'status':'unique_candidate' if len(offsets)==1 else 'ambiguous' if offsets else 'not_found'})
(out/'signatures.json').write_text(json.dumps(results,indent=2))
manifest={'rom':rom.name,'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'git_blob_sha1':blob,'core_commit':commit,'flash_base':'0x20000000','reset_candidate':'0x20000048','signature_scan_limit':'0x220000','scope':'Static analysis only. Signature matches are candidates, not validated function boundaries. No boot or decompilation performed.'}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
with (out/'strings.tsv').open('w') as f:
    f.write('offset\taddress\ttext\n')
    for m in re.finditer(rb'[\x20-\x7e]{6,}',data):
        f.write(f'{m.start():08x}\t{0x20000000+m.start():08x}\t{m.group().decode()}\n')
