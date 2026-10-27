import asyncio
import json
from types import SimpleNamespace
import httpx
import pytest
from app.core.config import settings
from app.core.http_security import RequestBoundary
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware
from scripts.dev_launcher import System
from app.run import validated_proxy_ips


def exchange(path, chunks=(), headers=(), *, handler=None):
    sent, reads = [], []
    messages = [{'type':'http.request','body':chunk,'more_body':i<len(chunks)-1} for i,chunk in enumerate(chunks)]
    async def receive():
        reads.append(True)
        return messages.pop(0) if messages else {'type':'http.disconnect'}
    async def send(message):
        sent.append(message)
    async def downstream(scope, receive, send):
        if handler:
            await handler(scope,receive,send)
        else:
            await send({'type':'http.response.start','status':200,'headers':[]})
            await send({'type':'http.response.body','body':b'ok'})
    scope = {'type':'http','path':path,'method':'POST','headers':list(headers)}
    asyncio.run(RequestBoundary(downstream)(scope,receive,send))
    return sent,reads


@pytest.mark.parametrize('path',['/api/v1/transcripts','/api/v1/audio-sessions/x/chunks','/api/v1/auth/me','/docs','/openapi.json','/redoc'])
def test_missing_bearer_rejected_without_consuming_body(path):
    sent,reads = exchange(path,[b'private data'])
    assert sent[0]['status']==401 and reads==[]
    assert (b'www-authenticate',b'Bearer') in sent[0]['headers']


@pytest.mark.parametrize('declared',[None,b'1',b'1400'])
def test_json_cap_before_buffering_including_false_or_missing_length(monkeypatch,declared):
    monkeypatch.setattr(settings,'max_json_request_bytes',1024)
    headers = [] if declared is None else [(b'content-length',declared)]
    sent,reads = exchange('/api/v1/auth/request-code',[b'x'*700,b'x'*700],headers)
    assert sent[0]['status']==413
    assert len(reads)==(0 if declared==b'1400' else 2)


def test_body_replayed_once_and_responses_not_cached():
    consumed=[]
    async def handler(scope,receive,send):
        consumed.append(await receive())
        await send({'type':'http.response.start','status':202,'headers':[]})
        await send({'type':'http.response.body','body':b'{}'})
    sent,_=exchange('/api/v1/auth/request-code',[b'{',b'}'],handler=handler)
    assert consumed==[{'type':'http.request','body':b'{}','more_body':False}]
    assert (b'cache-control',b'no-store') in sent[0]['headers']


@pytest.mark.parametrize('client,expected',[('203.0.113.10','203.0.113.10'),('127.0.0.2','198.51.100.1')])
def test_proxy_headers_trusted_only_from_configured_ip(client,expected):
    captured=[]
    async def app(scope,receive,send):
        captured.append(scope['client'][0])
    scope={'type':'http','client':(client,1234),'headers':[(b'x-forwarded-for',b'198.51.100.1'),(b'x-forwarded-proto',b'https')]}
    asyncio.run(ProxyHeadersMiddleware(app,trusted_hosts=['127.0.0.2'])(scope,None,None))
    assert captured==[expected]


@pytest.mark.parametrize('configured',[['*'],['0.0.0.0/0'],['::/0'],['not-an-IP']])
def test_all_address_or_invalid_proxy_trust_rejected(monkeypatch,configured):
    monkeypatch.setattr(settings,'trusted_proxy_ips',configured)
    with pytest.raises(ValueError):
        validated_proxy_ips()


def test_missing_smtp_password_fails_before_opening_connection(monkeypatch):
    import smtplib
    from app.integrations.email import SmtpEmailSender, EmailDeliveryError
    monkeypatch.setattr(settings,'smtp_host','smtp.example.org')
    monkeypatch.setattr(settings,'smtp_from_email','sender@example.org')
    monkeypatch.setattr(settings,'smtp_username','sender')
    monkeypatch.setattr(settings,'smtp_password','')
    monkeypatch.setattr(smtplib,'SMTP_SSL',lambda *a,**k:pytest.fail('Must not connect with incomplete credentials'))
    with pytest.raises(EmailDeliveryError):
        SmtpEmailSender().send_code('person@cbr.ru','123456')


@pytest.mark.parametrize('db_ready',[True,False])
def test_launcher_auth_probe_does_not_require_user_session(monkeypatch,tmp_path,db_ready):
    actual_client=httpx.Client
    def handle(request):
        if request.url.path=='/health':
            return httpx.Response(200,json={'status':'ok'})
        if request.url.path=='/api/v1/auth/me':
            return httpx.Response(401 if db_ready else 503,json={'error':{'code':'invalid_access_token' if db_ready else 'database_unavailable'}})
        return httpx.Response(401,json={'error':{'code':'authentication_required'}})
    monkeypatch.setattr(httpx,'Client',lambda **kwargs:actual_client(**kwargs,transport=httpx.MockTransport(handle)))
    system=System(SimpleNamespace(root=tmp_path))
    assert system.backend_ready() is db_ready
