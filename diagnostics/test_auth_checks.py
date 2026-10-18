import unittest
from auth_checks import is_auth_rejection


class AuthCheckTests(unittest.TestCase):
    def test_observed_expiry_is_a_rejection(self):
        self.assertTrue(is_auth_rejection('expired_token', 'INVALID_ARGUMENT', 'token has expired'))

    def test_standard_denials_are_rejections(self):
        for status in ['UNAUTHENTICATED', 'PERMISSION_DENIED']:
            self.assertTrue(is_auth_rejection('wrong_audience', status, 'denied'))

    def test_unrelated_argument_errors_do_not_pass(self):
        for detail in ['invalid image format', 'token might expire', 'invalid JWT header']:
            self.assertFalse(is_auth_rejection('expired_token', 'INVALID_ARGUMENT', detail))
        self.assertFalse(is_auth_rejection('wrong_audience', 'INVALID_ARGUMENT', 'token has expired'))

    def test_transport_failures_and_success_do_not_pass(self):
        for status in ['OK', 'UNAVAILABLE', 'DEADLINE_EXCEEDED', 'INTERNAL']:
            self.assertFalse(is_auth_rejection('expired_token', status, 'token has expired'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
