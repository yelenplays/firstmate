import os, ssl, socketserver, http.server, threading, json, subprocess, pathlib, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
root=pathlib.Path.cwd(); lab=root/'.test-post-merge'; evidence=pathlib.Path('/Users/marcocadornini/.no-mistakes/evidence/01M486HA14GEWR00GPK5EXZHZ0')
key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'api.github.com')])
now=datetime.datetime.now(datetime.timezone.utc)
cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.DNSName('api.github.com')]),False).add_extension(x509.BasicConstraints(ca=True,path_length=None),True).sign(key,hashes.SHA256())
(lab/'cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM)); (lab/'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption()))
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(lab/'cert.pem',lab/'key.pem')
mode='queued'; requests=[]; transcript=[]
sha='1'*40
class API(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); requests.append({'mode':mode,'path':self.path,'body':body})
  variables=body['variables']; assert type(variables['owner']) is str and type(variables['repo']) is str and type(variables['number']) is int
  pr={'state':'OPEN','isInMergeQueue':True,'mergeCommit':None,'headRefOid':'3'*40,'baseRefName':'main','id':'PR_lab7','title':'Lab change'}
  if mode=='merged': pr.update(state='MERGED',isInMergeQueue=False,mergeCommit={'oid':sha})
  if mode=='unqueued': pr['isInMergeQueue']=False
  if mode=='closed': pr.update(state='CLOSED',isInMergeQueue=False)
  data={'data':{'repository':{'pullRequest':None if mode=='null' else pr}}}
  self.respond(data,503 if mode=='error' else 200)
 def do_GET(self):
  requests.append({'mode':mode,'path':self.path})
  if 'check-runs' in self.path: data={'check_runs':[{'name':'build','status':'completed','conclusion':'success'}]}
  elif self.path.endswith('/status'): data={'statuses':[]}
  elif '/rules/' in self.path: data=[]
  else: data={'name':'main','protected':False}
  self.respond(data)
 def respond(self,data,status=200):
  data=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
class Proxy(socketserver.StreamRequestHandler):
 def handle(self):
  first=self.rfile.readline()
  while self.rfile.readline() not in (b'\r\n',b''): pass
  if first!=b'CONNECT api.github.com:443 HTTP/1.1\r\n': return
  self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
  with context.wrap_socket(self.connection,server_side=True) as conn: API(conn,self.client_address,self.server)
server=socketserver.ThreadingTCPServer(('127.0.0.1',0),Proxy); threading.Thread(target=server.serve_forever,daemon=True).start()
home=lab/'home'
for d in ['state','config','data','projects']: (home/d).mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(home),GH_CONFIG_DIR=str(lab/'gh-config'),GH_TOKEN='disposable-local-token',GITHUB_TOKEN='disposable-local-token',HTTPS_PROXY='http://127.0.0.1:'+str(server.server_address[1]),NO_PROXY='',SSL_CERT_FILE=str(lab/'cert.pem'),TMPDIR=str(lab/'tmp'))
def run(args,ok=True):
 p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 transcript.append('$ '+' '.join(args)+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
 assert (p.returncode==0)==ok,transcript[-1]
 return p.stdout
pm=['bin/fm-post-merge.sh']
def task(id,owner='acme',repo='widget'):
 (home/'state'/f'{id}.meta').write_text(f'project={lab}/widget\nmode=no-mistakes\nyolo=off\nbranch=feature\nspawn_gen=1\npr=https://github.com/{owner}/{repo}/pull/7\n')
def record(id): return (home/'state'/f'{id}.post-merge').read_text()
try:
 run(['gh','--version'])
 out=run(['gh','pr','view','https://github.com/acme/widget/pull/7','--json','state,isInMergeQueue,mergeCommit'],False); assert 'Unknown JSON field: "isInMergeQueue"' in out
 for identity in ['widget','2026','true','false','null']:
  mode='queued'; id='queue-'+identity; task(id,identity,identity)
  assert 'armed: post-merge watch for queued' in run(pm+['arm',id,'--no-witness','disposable API lab'])
  assert 'remains in GitHub' in run(pm+['advance',id])
  assert 'merge_commit=\n' in record(id)
 mode='merged'
 assert 'clear:' in run(pm+['advance','queue-widget'])
 assert 'merge_commit='+sha in record('queue-widget')
 run(pm+['status','queue-widget'])
 task('merged')
 assert 'armed:' in run(pm+['arm','merged','--no-witness','disposable API lab'])
 assert 'clear:' in run(pm+['advance','merged'])
 run(pm+['status','merged'])
 for state in ['unqueued','closed','null','error']:
  mode=state; task(state)
  run(pm+['arm',state,'--no-witness','disposable API lab'],False)
  assert not (home/'state'/f'{state}.post-merge').exists()
 mode='null'
 run(pm+['advance','queue-2026'],False)
 assert 'phase=checks' in record('queue-2026') and 'merge_commit=\n' in record('queue-2026')
 mode='queued'; assert 'remains in GitHub' in run(pm+['advance','queue-2026'])
 transcript.append('All disposable API scenarios completed. Real gh and real Firstmate CLI; no production requests or mutations.\n')
finally:
 server.shutdown(); server.server_close()
 (evidence/'live-cli.log').write_text('\n'.join(transcript))
 (evidence/'local-api-requests.json').write_text(json.dumps(requests,indent=2)+'\n')
