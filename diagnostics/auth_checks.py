"""Classify negative auth-test responses without accepting arbitrary RPC failures."""


def is_auth_rejection(label, status, detail):
    if status in ('UNAUTHENTICATED', 'PERMISSION_DENIED'):
        return True
    return (label == 'expired_token' and status == 'INVALID_ARGUMENT'
            and detail.strip().lower() == 'token has expired')
