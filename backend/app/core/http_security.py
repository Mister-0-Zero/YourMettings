"""Bound HTTP input before JSON buffering; require bearer presence before reading private input."""
from starlette.responses import JSONResponse
from app.core.config import settings


class PayloadTooLarge(Exception):
    pass


class RequestBoundary:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        path = scope.get('path', '')
        headers = dict(scope.get('headers', []))
        public = path in ('/api/v1/auth/request-code','/api/v1/auth/verify-code','/api/v1/auth/refresh')
        if (path.startswith('/api/v1/') and not public) or path in ('/docs','/redoc','/openapi.json'):
            bearer = headers.get(b'authorization', b'')
            if not bearer.lower().startswith(b'bearer ') or len(bearer) <= 7:
                response = JSONResponse({'error':{'code':'authentication_required','message':'Требуется вход в аккаунт.','details':{}}},
                    status_code=401, headers={'WWW-Authenticate':'Bearer','Cache-Control':'no-store'})
                return await response(scope, receive, send)
        limit = settings.audio_max_upload_bytes if path.startswith('/api/v1/audio-sessions/') and path.endswith('/chunks') else settings.max_json_request_bytes
        consumed = 0
        started = False
        async def bounded_receive():
            nonlocal consumed
            message = await receive()
            if message['type'] == 'http.request':
                consumed += len(message.get('body',b''))
                if consumed > limit:
                    raise PayloadTooLarge()
            return message
        async def secure_send(message):
            nonlocal started
            if message['type'] == 'http.response.start':
                started = True
                message['headers'] = list(message.get('headers', [])) + [(b'cache-control', b'no-store'),(b'x-content-type-options',b'nosniff')]
            await send(message)
        raw_length = headers.get(b'content-length')
        try:
            declared = int(raw_length) if raw_length is not None else None
        except ValueError:
            response = JSONResponse({'error':{'code':'invalid_content_length','message':'Недопустимый размер запроса.','details':{}}},status_code=400)
            return await response(scope, receive, secure_send)
        try:
            if declared is not None and (declared < 0 or declared > limit):
                raise PayloadTooLarge()
            audio_upload = path.startswith('/api/v1/audio-sessions/') and path.endswith('/chunks')
            if scope.get('method') in ('POST','PUT','PATCH') and not audio_upload:
                # FastAPI wraps receive exceptions while decoding JSON. Bound the
                # raw input here first so chunked/no-length requests also get 413.
                chunks = []
                while True:
                    message = await bounded_receive()
                    if message['type'] != 'http.request':
                        return
                    chunks.append(message.get('body', b''))
                    if not message.get('more_body'):
                        break
                payload = b''.join(chunks)
                delivered = False
                async def replay():
                    nonlocal delivered
                    if not delivered:
                        delivered = True
                        return {'type':'http.request','body':payload,'more_body':False}
                    return await receive()
                await self.app(scope, replay, secure_send)
            else:
                await self.app(scope, bounded_receive, secure_send)
        except PayloadTooLarge:
            if started:
                raise
            response = JSONResponse({'error':{'code':'request_too_large',
                'message':'Недопустимый размер запроса.','details':{}}},status_code=413)
            await response(scope, receive, secure_send)
