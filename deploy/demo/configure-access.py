"""Local operator tool: never prints the demo secret. Restart backend after changes."""
import argparse
import csv
import tempfile
from datetime import datetime,timedelta,timezone
import os
from pathlib import Path
import re
import secrets
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=('enable','rotate','disable'))
parser.add_argument('--hours',type=int,default=48)
args=parser.parse_args()
if not 1<=args.hours<=168:
    parser.error('Choose a temporary period from 1 to 168 hours')
repo=Path(__file__).resolve().parents[2]
envfile=repo/'backend/.env'
stamp=envfile.stat().st_mtime_ns
source=envfile.read_text(encoding='utf-8')
if subprocess.run(['git','-C',str(repo),'check-ignore','-q','backend/.env']).returncode:
    raise SystemExit('Refusing to store a secret in a non-ignored environment file')
updates={'DEMO_ENABLED':'false'}
keyfile=Path(os.environ.get('LOCALAPPDATA',Path.home()))/'YourMettings/demo-access-key.txt'
if args.action!='disable':
    existing=re.search(r'^DEMO_SECRET=([A-Za-z0-9_-]{43,256})$',source,re.M)
    key=existing.group(1) if existing and args.action=='enable' else secrets.token_urlsafe(48)
    expiry=datetime.now(timezone.utc)+timedelta(hours=args.hours)
    updates.update(DEMO_ENABLED='true',DEMO_SECRET=key,DEMO_EXPIRES_AT=expiry.isoformat(),
        BACKEND_LAN_ENABLED='false',TRUSTED_PROXY_IPS='["127.0.0.1"]')
    keyfile.parent.mkdir(parents=True,exist_ok=True)
    descriptor,temporary=tempfile.mkstemp(prefix='.demo-key-',dir=keyfile.parent)
    os.close(descriptor)
    pending=Path(temporary)
    if os.name=='nt':
        identity=subprocess.run(['whoami.exe','/user','/fo','csv','/nh'],capture_output=True,check=True,text=True)
        sid=next(csv.reader(identity.stdout.splitlines()))[-1].strip()
        if not re.fullmatch(r'S-1-[0-9-]+',sid):
            pending.unlink()
            raise SystemExit('Cannot identify the current Windows user')
        try:
            subprocess.run(['icacls.exe',str(pending),'/inheritance:r','/grant:r',f'*{sid}:(F)'],
                capture_output=True,check=True)
        except BaseException:
            pending.unlink(missing_ok=True)
            raise
    else:
        pending.chmod(0o600)
    # The file is private before any secret bytes are written.
    pending.write_text(key+'\n',encoding='utf-8')
for name,value in updates.items():
    pattern=re.compile(r'^'+name+r'=.*$',re.M)
    source=pattern.sub(lambda _:name+'='+value,source) if pattern.search(source) else source.rstrip()+'\n'+name+'='+value+'\n'
if envfile.stat().st_mtime_ns!=stamp:
    if args.action!='disable':
        pending.unlink(missing_ok=True)
    raise SystemExit('Environment changed concurrently; no configuration/key replacement performed')
original=envfile.read_text(encoding='utf-8')
try:
    envfile.write_text(source,encoding='utf-8')
    if args.action!='disable':
        try:
            os.replace(pending,keyfile)
        except OSError:
            if envfile.read_text(encoding='utf-8')==source:
                envfile.write_text(original,encoding='utf-8')
            raise
        print('Private key file:',keyfile)
        print('Expires UTC:',expiry.isoformat())
finally:
    if args.action!='disable':
        pending.unlink(missing_ok=True)
print('Configuration updated. Backend restart required; no secret printed.')
if args.action=='disable':
    print('Network bindings remain unchanged (loopback-only). Close the gateway before disabling demo mode.')
