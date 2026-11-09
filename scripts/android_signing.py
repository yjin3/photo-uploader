"""Create a persistent APK signing key once, or restore and verify it in CI.

Private material stays in ignored .signing/ locally, or RUNNER_TEMP in CI.
This script never prints passwords, keystore bytes, or GitHub secret values.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = ROOT / 'android' / 'release-certificate.sha256'
ALIAS = 'photo-uploader'


def keytool():
    executable = shutil.which('keytool')
    if executable:
        return executable
    candidates = [Path(os.environ.get('JAVA_HOME', '.')) / 'bin' / 'keytool.exe']
    if os.name == 'nt':
        candidates.extend(Path('C:/Program Files/Android/openjdk').glob('*/bin/keytool.exe'))
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError('Java keytool is required to create/verify the signing key.')


def run_keytool(arguments, password):
    env = os.environ.copy()
    env['PHOTO_SIGNING_PASSWORD'] = password
    result = subprocess.run([keytool(), *arguments], env=env, capture_output=True)
    if result.returncode:
        raise RuntimeError('keytool failed. Check the keystore, password and Java installation.')
    return result.stdout


def certificate_digest(path, password):
    certificate = run_keytool(['-exportcert', '-alias', ALIAS, '-keystore', str(path),
        '-storetype', 'PKCS12', '-storepass:env', 'PHOTO_SIGNING_PASSWORD'], password)
    return hashlib.sha256(certificate).hexdigest()


def verify(path, password):
    actual = certificate_digest(path, password)
    expected = FINGERPRINT.read_text(encoding='ascii').strip().lower()
    if actual != expected:
        raise RuntimeError('Signing certificate differs from this app. Restore the original signing key.')
    print('Release signing certificate verified: ' + actual)


def write_private(path, content):
    path.write_bytes(content)
    path.chmod(0o600)


def create():
    directory = ROOT / '.signing'
    keystore = directory / 'photo-uploader-release.p12'
    bundle = directory / 'github-secrets.json'
    if keystore.exists() != bundle.exists():
        raise RuntimeError('Incomplete signing backup. Restore the existing key; do not replace it.')
    if not keystore.exists():
        if FINGERPRINT.exists():
            raise RuntimeError('This app already has a signing certificate. Restore its .signing backup.')
        directory.mkdir(mode=0o700, exist_ok=True)
        password = secrets.token_urlsafe(32)
        run_keytool(['-genkeypair', '-noprompt', '-keystore', str(keystore),
            '-alias', ALIAS, '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
            '-storetype', 'PKCS12', '-dname', 'CN=Photo Uploader',
            '-storepass:env', 'PHOTO_SIGNING_PASSWORD', '-keypass:env', 'PHOTO_SIGNING_PASSWORD'], password)
        keystore.chmod(0o600)
        write_private(bundle, json.dumps({
            'ANDROID_KEYSTORE_BASE64': base64.b64encode(keystore.read_bytes()).decode('ascii'),
            'ANDROID_KEYSTORE_PASSWORD': password,
        }, indent=2).encode('ascii'))
        FINGERPRINT.write_text(certificate_digest(keystore, password) + '\n', encoding='ascii')
    data = json.loads(bundle.read_text(encoding='ascii'))
    if base64.b64decode(data['ANDROID_KEYSTORE_BASE64'], validate=True) != keystore.read_bytes():
        raise RuntimeError('Signing backup does not match the keystore.')
    password = data['ANDROID_KEYSTORE_PASSWORD']
    verify(keystore, password)
    properties = ('storeFile=../../.signing/photo-uploader-release.p12\n'
        'storeType=PKCS12\nkeyAlias=' + ALIAS + '\nstorePassword=' + password + '\nkeyPassword=' + password + '\n')
    write_private(ROOT / 'android' / 'key.properties', properties.encode('ascii'))
    print('Signing key and local Gradle configuration ready. Private backup: .signing/')


def restore(path):
    encoded = os.environ.get('ANDROID_KEYSTORE_BASE64', '')
    password = os.environ.get('ANDROID_KEYSTORE_PASSWORD', '')
    if not encoded or not password:
        raise RuntimeError('Set repository Actions secrets ANDROID_KEYSTORE_BASE64 and ANDROID_KEYSTORE_PASSWORD.')
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        write_private(path, base64.b64decode(encoded, validate=True))
        verify(path, password)
    except Exception:
        path.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    subparsers.add_parser('create')
    restore_parser = subparsers.add_parser('restore')
    restore_parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == 'create':
            create()
        else:
            restore(arguments.output)
    except Exception as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
