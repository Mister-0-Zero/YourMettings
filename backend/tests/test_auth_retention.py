from datetime import datetime,timedelta,timezone
from uuid import uuid4
from app.auth_models import AuthSession,AuthRenewalToken,EmailChallenge
from app.db.session import TEST_USER_ID
from app.services.auth_maintenance import cleanup_auth_records


def test_cleanup_keeps_active_reuse_evidence_and_day_limit_history(database):
    now=datetime.now(timezone.utc)
    with database.begin() as db:
        active=AuthSession(user_id=TEST_USER_ID,kind='remembered',created_at=now-timedelta(days=2),expires_at=now+timedelta(days=28))
        expired=AuthSession(user_id=TEST_USER_ID,kind='remembered',created_at=now-timedelta(days=33),expires_at=now-timedelta(days=2))
        db.add_all([active,expired]); db.flush()
        db.add(AuthRenewalToken(token_hash='a'*64,session_id=active.id,used_at=now-timedelta(days=1)))
        db.add(AuthRenewalToken(token_hash='b'*64,session_id=expired.id))
        old_id,recent_id=uuid4(),uuid4()
        for identifier,age in ((old_id,2),(recent_id,0)):
            db.add(EmailChallenge(id=identifier,email='rate@cbr.ru',ip_hash='c'*64,code_hash='d'*64,attempts=0,
                created_at=now-timedelta(days=age,minutes=20),expires_at=now-timedelta(days=age,minutes=10)))
    with database.begin() as db:
        cleanup_auth_records(db)
    with database() as db:
        assert db.get(AuthRenewalToken,'a'*64) is not None
        assert db.get(AuthRenewalToken,'b'*64) is None
        assert db.get(EmailChallenge,old_id) is None
        assert db.get(EmailChallenge,recent_id) is not None
