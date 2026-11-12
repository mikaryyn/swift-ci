#!/usr/bin/env bash
# Regenerates the fastlane match fixtures next to this script. Everything is built in a new temporary directory, and
# then `plain/`, `v1/`, `v2/` and `extra/` are replaced. The README.md of this directory is not touched.
#
# The files are encrypted with fastlane's own encryption code (match/lib/match/encryption/encryption.rb), so they are
# what fastlane writes. Tools, all overridable by environment variables:
#
#   OPENSSL       openssl binary (default /opt/homebrew/bin/openssl; /usr/bin/openssl is LibreSSL and is not used)
#   RUBY          Ruby that runs fastlane's code (default /opt/homebrew/opt/ruby/bin/ruby)
#   FASTLANE_DIR  the fastlane gem directory (default /opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.232.2)
#
# Usage:
#
#   Tests/SwiftCISigningTests/Fixtures/Match/make-fixtures.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL="${OPENSSL:-/opt/homebrew/bin/openssl}"
RUBY="${RUBY:-/opt/homebrew/opt/ruby/bin/ruby}"
FASTLANE_DIR="${FASTLANE_DIR:-/opt/homebrew/lib/ruby/gems/4.0.0/gems/fastlane-2.232.2}"

PASSWORD="fixture-password"
TEAM="TEAMID1234"
OTHER_TEAM="OTHERTEAM1"
CERT_ID="CERTID1234"
SECOND_CERT_ID="CERTID9999"
EXPIRED_CERT_ID="CERTIDEXPD"
MATCH_VERSION="2.232.2"

fail() {
    echo "make-fixtures.sh: $*" >&2
    exit 1
}

[[ -x "$OPENSSL" ]] || fail "openssl not found at $OPENSSL. Set OPENSSL to an openssl binary."
[[ -x "$RUBY" ]] || fail "ruby not found at $RUBY. Set RUBY to the Ruby that runs fastlane."
[[ -d "$FASTLANE_DIR/match/lib" ]] || fail "fastlane not found at $FASTLANE_DIR. Set FASTLANE_DIR to the fastlane gem directory."

work="$(mktemp -d "${TMPDIR:-/tmp}/swiftci-match-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT

generated_date="$(date -u +%Y-%m-%d)"
creation_date="${generated_date}T00:00:00Z"
expiration_date="$("$RUBY" -rdate -e 'print (Date.parse(ARGV[0]) + 7300).strftime("%Y-%m-%dT00:00:00Z")' "$generated_date")"

# Encrypts `input` into `output` with fastlane's code. `version` is 1 or 2. `hash_algorithm` is MD5 or SHA256, and it
# applies to version 1 only. SHA256 is written as fastlane's MatchDataEncryption#encrypt writes it, with the v1 prefix.
encrypt() {
    local input="$1" output="$2" version="$3" hash_algorithm="$4"
    MATCH_FIXTURE_PASSWORD="$PASSWORD" "$RUBY" -I "$FASTLANE_DIR/match/lib" -e '
require "base64"
require "securerandom"
require "match/encryption/encryption"
input, output, version, hash_algorithm = ARGV
password = ENV.fetch("MATCH_FIXTURE_PASSWORD")
data = File.binread(input)
if hash_algorithm == "SHA256"
  salt = SecureRandom.random_bytes(8)
  encrypted = Match::Encryption::EncryptionV1.new.encrypt(data: data, password: password, salt: salt, hash_algorithm: "SHA256")[:encrypted_data]
  File.binwrite(output, Base64.encode64("Salted__".b + salt + encrypted))
else
  File.binwrite(output, Match::Encryption::MatchDataEncryption.new.encrypt(data: data, password: password, version: version.to_i))
end
' "$input" "$output" "$version" "$hash_algorithm"
    # fastlane writes base64 with line breaks every 60 characters. A file without them is not what fastlane writes.
    [[ $(wc -l < "$output") -ge 2 ]] || fail "$output has no line breaks"
}

# Encrypts every .cer, .p12 and .mobileprovision file below `dir` in place.
encrypt_tree() {
    local dir="$1" version="$2" hash_algorithm="$3" file
    while IFS= read -r -d '' file; do
        encrypt "$file" "$file.encrypted" "$version" "$hash_algorithm"
        mv "$file.encrypted" "$file"
    done < <(find "$dir" -type f \( -name '*.cer' -o -name '*.p12' -o -name '*.mobileprovision' \) -print0)
}

# new_certificate <base name> <common name> <validity options of openssl req -x509>
# Writes, in $work, <base>.key.pem (a traditional PKCS#1 RSA key, as fastlane's OpenSSL::PKey::RSA#to_s writes it),
# <base>.cert.pem and <base>.cer.der (the DER certificate).
new_certificate() {
    local base="$1" common_name="$2"
    shift 2
    "$OPENSSL" genrsa -out "$work/$base.pkcs8.pem" 2048 2>/dev/null
    "$OPENSSL" rsa -in "$work/$base.pkcs8.pem" -traditional -out "$work/$base.key.pem" 2>/dev/null
    [[ "$(head -n 1 "$work/$base.key.pem")" == '-----BEGIN RSA PRIVATE KEY-----' ]] || fail "the private key of $base is not a traditional RSA PEM key"

    "$OPENSSL" req -x509 -new -key "$work/$base.key.pem" -sha256 \
        -subj "/C=US/O=SwiftCI Test/OU=$TEAM/CN=$common_name" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:FALSE" \
        "$@" -out "$work/$base.cert.pem" 2>/dev/null
    "$OPENSSL" x509 -in "$work/$base.cert.pem" -outform der -out "$work/$base.cer.der"
}

# A provisioning profile, signed as Xcode and fastlane store them: CMS, DER, with the content attached. The signer is
# the main test certificate. The profile lists the DER certificate `cert_der` in DeveloperCertificates.
# write_profile <file base name> <profile type> <bundle identifier> <team> <creation date> <expiration date> <UUID> <cert_der>
write_profile() {
    local base="$1" profile_type="$2" app_id="$3" team="$4" created="$5" expires="$6" uuid="$7" cert_der="$8"
    local cert_base64
    cert_base64="$("$OPENSSL" base64 -A -in "$cert_der")"
    cat > "$work/profile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppIDName</key>
	<string>SwiftCI Example App</string>
	<key>ApplicationIdentifierPrefix</key>
	<array>
		<string>$team</string>
	</array>
	<key>CreationDate</key>
	<date>$created</date>
	<key>Platform</key>
	<array>
		<string>iOS</string>
	</array>
	<key>DeveloperCertificates</key>
	<array>
		<data>$cert_base64</data>
	</array>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key>
		<string>$team.$app_id</string>
		<key>com.apple.developer.team-identifier</key>
		<string>$team</string>
		<key>get-task-allow</key>
		<false/>
		<key>keychain-access-groups</key>
		<array>
			<string>$team.*</string>
		</array>
	</dict>
	<key>ExpirationDate</key>
	<date>$expires</date>
	<key>Name</key>
	<string>match $profile_type $app_id</string>
	<key>ProvisionedDevices</key>
	<array>
		<string>00000000-0000000000000001</string>
	</array>
	<key>TeamIdentifier</key>
	<array>
		<string>$team</string>
	</array>
	<key>TeamName</key>
	<string>SwiftCI Test</string>
	<key>TimeToLive</key>
	<integer>365</integer>
	<key>UUID</key>
	<string>$uuid</string>
	<key>Version</key>
	<integer>1</integer>
</dict>
</plist>
PLIST
    "$OPENSSL" cms -sign -nodetach -binary -outform der \
        -signer "$work/main.cert.pem" -inkey "$work/main.key.pem" \
        -in "$work/profile.plist" -out "$base.mobileprovision"
}

# The certificates. The main one signs the profiles. The second one is in the repository, and no profile uses it. The
# expired one is in the repository, and its validity ended on 2020-01-01. The stranger one is in a profile only, and it
# is not stored in the repository.
new_certificate main "SwiftCI Test Distribution ($TEAM)" -days 7300
new_certificate second "SwiftCI Test Distribution 2 ($TEAM)" -days 7300
new_certificate expired "SwiftCI Test Distribution Expired ($TEAM)" -not_before 20190101000000Z -not_after 20200101000000Z
new_certificate stranger "SwiftCI Test Distribution Stranger ($TEAM)" -days 7300

# plain/: the repository as fastlane match lays it out, unencrypted.
plain="$work/plain"
mkdir -p "$plain/certs/distribution" "$plain/profiles/adhoc" "$plain/profiles/appstore"
cp "$work/main.cer.der" "$plain/certs/distribution/$CERT_ID.cer"
cp "$work/main.key.pem" "$plain/certs/distribution/$CERT_ID.p12"
cp "$work/second.cer.der" "$plain/certs/distribution/$SECOND_CERT_ID.cer"
cp "$work/second.key.pem" "$plain/certs/distribution/$SECOND_CERT_ID.p12"
cp "$work/expired.cer.der" "$plain/certs/distribution/$EXPIRED_CERT_ID.cer"
cp "$work/expired.key.pem" "$plain/certs/distribution/$EXPIRED_CERT_ID.p12"
printf '%s\n' "$MATCH_VERSION" > "$plain/match_version.txt"
cat > "$plain/README.md" <<README
# Certificates

This is a test fixture of SwiftCI for fastlane match. It is not a real match repository, and its key signs nothing real.
README

write_profile "$plain/profiles/adhoc/AdHoc_com.example.app1" AdHoc "com.example.app1" "$TEAM" \
    "$creation_date" "$expiration_date" "11111111-1111-4111-8111-111111111111" "$work/main.cer.der"
write_profile "$plain/profiles/adhoc/AdHoc_com.example.app2" AdHoc "com.example.app2" "$TEAM" \
    "$creation_date" "$expiration_date" "22222222-2222-4222-8222-222222222222" "$work/main.cer.der"
write_profile "$plain/profiles/adhoc/AdHoc_com.example.otherteam" AdHoc "com.example.otherteam" "$OTHER_TEAM" \
    "$creation_date" "$expiration_date" "33333333-3333-4333-8333-333333333333" "$work/main.cer.der"
write_profile "$plain/profiles/adhoc/AdHoc_com.example.expired" AdHoc "com.example.expired" "$TEAM" \
    "2019-01-01T00:00:00Z" "2020-01-01T00:00:00Z" "44444444-4444-4444-8444-444444444444" "$work/main.cer.der"
write_profile "$plain/profiles/adhoc/AdHoc_com.example.expiredcert" AdHoc "com.example.expiredcert" "$TEAM" \
    "$creation_date" "$expiration_date" "66666666-6666-4666-8666-666666666666" "$work/expired.cer.der"
write_profile "$plain/profiles/adhoc/AdHoc_com.example.nocert" AdHoc "com.example.nocert" "$TEAM" \
    "$creation_date" "$expiration_date" "77777777-7777-4777-8777-777777777777" "$work/stranger.cer.der"
write_profile "$plain/profiles/appstore/AppStore_com.example.app1" AppStore "com.example.app1" "$TEAM" \
    "$creation_date" "$expiration_date" "55555555-5555-4555-8555-555555555555" "$work/main.cer.der"

# v1 and v2: the same repository, with every .cer, .p12 and .mobileprovision file encrypted.
cp -R "$plain" "$work/v1"
encrypt_tree "$work/v1" 1 MD5
cp -R "$plain" "$work/v2"
encrypt_tree "$work/v2" 2 MD5

# extra/: the SHA-256 fallback of v1, and PKCS#12 keys as `match import` can store them.
extra="$work/extra"
mkdir -p "$extra/v1-sha256/certs/distribution" "$extra/pkcs12/plain/certs/distribution" "$extra/pkcs12/v2/certs/distribution"
cp "$work/main.cer.der" "$extra/v1-sha256/certs/distribution/$CERT_ID.cer"
encrypt "$extra/v1-sha256/certs/distribution/$CERT_ID.cer" "$work/sha256.enc" 1 SHA256
mv "$work/sha256.enc" "$extra/v1-sha256/certs/distribution/$CERT_ID.cer"

"$OPENSSL" pkcs12 -export -legacy -passout pass: -inkey "$work/main.key.pem" -in "$work/main.cert.pem" \
    -out "$extra/pkcs12/plain/certs/distribution/$CERT_ID.p12" 2>/dev/null
cp "$extra/pkcs12/plain/certs/distribution/$CERT_ID.p12" "$extra/pkcs12/v2/certs/distribution/$CERT_ID.p12"
encrypt "$extra/pkcs12/v2/certs/distribution/$CERT_ID.p12" "$work/pkcs12.enc" 2 MD5
mv "$work/pkcs12.enc" "$extra/pkcs12/v2/certs/distribution/$CERT_ID.p12"

# Replace the outputs only after everything was built.
for name in plain v1 v2; do
    rm -rf "$here/$name"
    cp -R "$work/$name" "$here/$name"
done
rm -rf "$here/extra"
cp -R "$extra" "$here/extra"

echo "Regenerated the match fixtures in $here on $generated_date."
