import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "release_secrets", Path(__file__).resolve().parents[1] / "scripts/configure-release-secrets.py"
)
release_secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_secrets)


class ReleaseSecretsChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="prumo-synthetic-certificate.")
        cls.root = Path(cls.directory.name)
        cls.password = " synthetic export $ ' café password "
        cls.certificate = cls.root / "synthetic.p12"
        subprocess.run(
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(cls.root / "key.pem"), "-out", str(cls.root / "cert.pem"),
             "-days", "1", "-subj", "/CN=Prumo Synthetic Test"],
            check=True, capture_output=True,
        )
        environment = os.environ.copy()
        environment["PRUMO_TEST_PASSWORD"] = cls.password
        subprocess.run(
            ["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(cls.root / "key.pem"),
             "-in", str(cls.root / "cert.pem"), "-out", str(cls.certificate),
             "-passout", "env:PRUMO_TEST_PASSWORD"],
            env=environment, check=True, capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_valid_backup_accepts_unicode_and_spaces_with_incompatible_openssl_on_path(self):
        incompatible = self.root / "openssl"
        incompatible.write_text("#!/bin/sh\nexit 99\n")
        incompatible.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.root)}):
            release_secrets.validate_certificate(self.certificate, self.password)

    def test_wrong_password_reports_the_certificate_error(self):
        with self.assertRaisesRegex(ValueError, "(?i)mac verify error"):
            release_secrets.validate_certificate(self.certificate, "incorrect-synthetic-password")

    def test_malformed_backup_reports_validation_failure(self):
        malformed = self.root / "malformed.p12"
        malformed.write_bytes(b"not a certificate")
        with self.assertRaisesRegex(ValueError, "Certificate validation failed"):
            release_secrets.validate_certificate(malformed, self.password)


if __name__ == "__main__":
    unittest.main()
