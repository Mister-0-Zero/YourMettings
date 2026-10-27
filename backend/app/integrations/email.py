"""TLS-only SMTP adapter. Tests replace get_email_sender using dependency overrides."""
import smtplib
import ssl
from email.message import EmailMessage
from typing import Protocol

from app.core.config import settings


class EmailDeliveryError(Exception):
    pass


class EmailSender(Protocol):
    def send_code(self, recipient: str, code: str) -> None: ...


class SmtpEmailSender:
    def send_code(self, recipient: str, code: str) -> None:
        host = settings.smtp_host
        sender = settings.smtp_from_email
        security = settings.smtp_security
        if (not host or not sender or security not in ("ssl", "starttls")
                or bool(settings.smtp_username) != bool(settings.smtp_password)):
            raise EmailDeliveryError("Email delivery is not configured")
        msg = EmailMessage()
        msg["Subject"] = "YourMettings: код входа"
        msg["From"] = sender
        msg["To"] = recipient
        msg.set_content(f"Код входа в YourMettings: {code}\nДействует 10 минут. Никому не сообщайте код.")
        context = ssl.create_default_context()
        try:
            if security == "ssl":
                transport = smtplib.SMTP_SSL(host, settings.smtp_port, timeout=10, context=context)
            else:
                transport = smtplib.SMTP(host, settings.smtp_port, timeout=10)
            with transport as smtp:
                if security == "starttls":
                    smtp.ehlo()
                    smtp.starttls(context=context)
                    smtp.ehlo()
                if settings.smtp_username:
                    smtp.login(settings.smtp_username, settings.smtp_password)
                smtp.send_message(msg)
        except (OSError, smtplib.SMTPException, ValueError) as exc:
            # Never expose server diagnostics: they can contain addresses and credentials.
            raise EmailDeliveryError("Email delivery unavailable") from exc


def get_email_sender() -> EmailSender:
    return SmtpEmailSender()
