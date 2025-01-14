#!/bin/bash -e
# Copyright (C) 2024 Simo Sorce <simo@redhat.com>
# SPDX-License-Identifier: Apache-2.0

source "${TESTSSRCDIR}/helpers.sh"

if ! command -v p11tool &> /dev/null
then
    echo "GnuTLS utils are required"
    exit 0
fi

# On macOS, /usr/bin/certtool is a different program. Both MacPorts and
# Homebrew rename GnuTLS' certtool to gnutls-certtool, so check for that first.
#
# https://github.com/macports/macports-ports/blob/4494b720a4807ddfc18bddf876620a5c6b24ce4f/devel/gnutls/Portfile#L206-L209
# https://github.com/Homebrew/homebrew-core/blob/83be349adb47980b4046258b74fa8c1e99ca96a3/Formula/gnutls.rb#L56-L58
if [ "$(uname)" == "Darwin" ]; then
    certtool=$(type -p gnutls-certtool)
else
    certtool=$(type -p certtool)
fi
if [ -z "$certtool" ]; then
    echo "Missing GnuTLS certtool (on macOS, commonly installed as gnutls-certtool)"
    exit 0
fi

# macOS uses BSD sed, which expects the argument after -i (with a space after
# it!) to be the backup suffix, while GNU sed expects a potential backup suffix
# directly after -i and interprets -i <expression> as in-place editing with no
# backup.
#
# Use "${sed_inplace[@]}" to make that work transparently by setting it to the
# arguments required to achieve in-place editing without backups depending on
# the version of sed.
#
if sed --version 2>/dev/null | grep -q 'GNU sed'; then
	sed_inplace=("-i")
else
	sed_inplace=("-i" "")
fi

title SECTION "Searching for Cryoptic module"

find_kryoptic() {
    for _lib in "$@" ; do
        if test -f "$_lib" ; then
            echo "Using kryoptic path $_lib"
            P11LIB="$_lib"
            return
        fi
    done
    echo "skipped: Unable to find kryoptic PKCS#11 library"
    exit 0
}

find_kryoptic \
    "${KRYOPTIC}/target/debug/libkryoptic_pkcs11.so" \
    "${KRYOPTIC}/target/release/libkryoptic_pkcs11.so" \
    /usr/local/lib/kryoptic/libkryoptic_pkcs11so \
    /usr/lib64/pkcs11/libkryoptic_pkcs11.so \
    /usr/lib/pkcs11/libkryoptic_pkcs11.so \
    /usr/lib/x86_64-linux-gnu/kryoptic/libkryoptic_pkcs11.so

title SECTION "Set up Kryoptic token"

TMPPDIR="${TESTBLDDIR}/tmp.kryoptic"
if [ -d "${TMPPDIR}" ]; then
    rm -fr "${TMPPDIR}"
fi
mkdir "${TMPPDIR}"

PINVALUE="12345678"
PINFILE="${TMPPDIR}/pinfile.txt"
echo ${PINVALUE} > "${PINFILE}"

#RANDOM data
SEEDFILE="${TMPPDIR}/noisefile.bin"
dd if=/dev/urandom of="${SEEDFILE}" bs=2048 count=1 >/dev/null 2>&1
RAND64FILE="${TMPPDIR}/64krandom.bin"
dd if=/dev/urandom of="${RAND64FILE}" bs=2048 count=32 >/dev/null 2>&1

# Create brand new tokens and certs
TOKDIR="$TMPPDIR/tokens"
if [ -d "${TOKDIR}" ]; then
    rm -fr "${TOKDIR}"
fi
mkdir "${TOKDIR}"

# Kryoptic configuration
export KRYOPTIC_CONF="$TMPPDIR/tokens/kryoptic.sql"

title LINE "Creating Kyroptic database"

export GNUTLS_SO_PIN=${PINVALUE}
p11tool --provider="${P11LIB}" --initialize \
    --label="Test" \
    "pkcs11:manufacturer=Kryoptic%20Project" 2>&1
unset GNUTLS_SO_PIN

title LINE "Setting User PIN"
# For some reason currently p11tool requires adding extraneous %00 termination
# marks at the end of the manufacturer and token names when using the
# --initialize-pin option
export GNUTLS_PIN=${PINVALUE}
p11tool --provider="${P11LIB}" --initialize-pin \
    "pkcs11:manufacturer=Kryoptic%20Project%00;token=Test%00" 2>&1


P11DEFARGS="--module=${P11LIB} --login --pin=${PINVALUE}"

# General cert configs
cat >> "${TMPPDIR}/cert.cfg" <<HEREDOC
ca
cn = "Issuer"
serial = 1
expiration_days = 365
email = "testcert@example.org"
signing_key
encryption_key
HEREDOC
SERIAL=1


title LINE "Creating new Self Sign CA"
KEYID='0000'
URIKEYID="%00%00"
CACRT="${TMPPDIR}/CAcert"
CACRTN="caCert"


((SERIAL+=1))
# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="RSA:2048" \
	--label="${CACRTN}" --id="${KEYID}" 2>&1
"${certtool}" --generate-self-signed --outfile="${CACRT}.crt" \
	--template="${TMPPDIR}/cert.cfg" --provider="$P11LIB" \
        --load-privkey "pkcs11:object=$CACRTN;type=private" \
        --load-pubkey "pkcs11:object=$CACRTN;type=public" --outder 2>&1
# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --write-object "${CACRT}.crt" --type=cert \
        --id=$KEYID --label="$CACRTN" 2>&1

# the organization identification is not in the CA
echo 'organization = "PKCS11 Provider"' >> "${TMPPDIR}/cert.cfg"

ca_sign() {
    CRT=$1
    LABEL=$2
    CN=$3
    KEYID=$4
    ((SERIAL+=1))
    sed -e "s|cn = .*|cn = $CN|g" \
        -e "s|serial = .*|serial = $SERIAL|g" \
        -e "/^ca$/d" \
        "${sed_inplace[@]}" \
        "${TMPPDIR}/cert.cfg"
    "${certtool}" --generate-certificate --outfile="${CRT}.crt" \
        --template="${TMPPDIR}/cert.cfg" --provider="$P11LIB" \
	--load-privkey "pkcs11:object=$LABEL;type=private" \
        --load-pubkey "pkcs11:object=$LABEL;type=public" --outder \
        --load-ca-certificate "${CACRT}.crt" --inder \
        --load-ca-privkey="pkcs11:object=$CACRTN;type=private" 2>&1
# shellcheck disable=SC2086
    pkcs11-tool ${P11DEFARGS} --write-object "${CRT}.crt" --type=cert \
        --id="$KEYID" --label="$LABEL" 2>&1
}

# generate RSA key pair and self-signed certificate
KEYID='0001'
URIKEYID="%00%01"
TSTCRT="${TMPPDIR}/testcert"
TSTCRTN="testCert"

# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="RSA:2048" \
	--label="${TSTCRTN}" --id="$KEYID"
ca_sign "$TSTCRT" $TSTCRTN "My Test Cert" $KEYID

BASEURIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
BASEURIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file:${PINFILE}"
BASEURI="pkcs11:id=${URIKEYID}"
PUBURI="pkcs11:type=public;id=${URIKEYID}"
PRIURI="pkcs11:type=private;id=${URIKEYID}"
CRTURI="pkcs11:type=cert;object=${TSTCRTN}"

title LINE "RSA PKCS11 URIS"
echo "${BASEURIWITHPINVALUE}"
echo "${BASEURIWITHPINSOURCE}"
echo "${BASEURI}"
echo "${PUBURI}"
echo "${PRIURI}"
echo "${CRTURI}"
echo ""

# generate ECC key pair
KEYID='0002'
URIKEYID="%00%02"
ECCRT="${TMPPDIR}/eccert"
ECCRTN="ecCert"

# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="EC:secp256r1" \
	--label="${ECCRTN}" --id="$KEYID"
ca_sign "$ECCRT" $ECCRTN "My EC Cert" $KEYID

ECBASEURIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
ECBASEURIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file:${PINFILE}"
ECBASEURI="pkcs11:id=${URIKEYID}"
ECPUBURI="pkcs11:type=public;id=${URIKEYID}"
ECPRIURI="pkcs11:type=private;id=${URIKEYID}"
ECCRTURI="pkcs11:type=cert;object=${ECCRTN}"

KEYID='0003'
URIKEYID="%00%03"
ECPEERCRT="${TMPPDIR}/ecpeercert"
ECPEERCRTN="ecPeerCert"

# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="EC:secp256r1" \
	--label="$ECPEERCRTN" --id="$KEYID"
ca_sign "$ECPEERCRT" $ECPEERCRTN "My Peer EC Cert" $KEYID

ECPEERBASEURIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
ECPEERBASEURIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file:${PINFILE}"
ECPEERBASEURI="pkcs11:id=${URIKEYID}"
ECPEERPUBURI="pkcs11:type=public;id=${URIKEYID}"
ECPEERPRIURI="pkcs11:type=private;id=${URIKEYID}"
ECPEERCRTURI="pkcs11:type=cert;object=${ECPEERCRTN}"

title LINE "EC PKCS11 URIS"
echo "${ECBASEURIWITHPINVALUE}"
echo "${ECBASEURIWITHPINSOURCE}"
echo "${ECBASEURI}"
echo "${ECPUBURI}"
echo "${ECPRIURI}"
echo "${ECCRTURI}"
echo "${ECPEERBASEURIWITHPINVALUE}"
echo "${ECPEERBASEURIWITHPINSOURCE}"
echo "${ECPEERBASEURI}"
echo "${ECPEERPUBURI}"
echo "${ECPEERPRIURI}"
echo "${ECPEERCRTURI}"
echo ""

# TODO: not supported yet by Kryoptic
## generate ED25519
#KEYID='0004'
#URIKEYID="%00%04"
#EDCRT="${TMPPDIR}/edcert"
#EDCRTN="edCert"
#
## shellcheck disable=SC2086
#pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="EC:edwards25519" \
#	--label="${EDCRTN}" --id="$KEYID"
#ca_sign "$EDCRT" $EDCRTN "My ED25519 Cert" $KEYID
#
#EDBASEURIWITHPINVALUE="pkcs11:id=${URIKEYID};pin-value=${PINVALUE}"
#EDBASEURIWITHPINSOURCE="pkcs11:id=${URIKEYID};pin-source=file:${PINFILE}"
#EDBASEURI="pkcs11:id=${URIKEYID}"
#EDPUBURI="pkcs11:type=public;id=${URIKEYID}"
#EDPRIURI="pkcs11:type=private;id=${URIKEYID}"
#EDCRTURI="pkcs11:type=cert;object=${EDCRTN}"
#
#title LINE "ED25519 PKCS11 URIS"
#echo "${EDBASEURIWITHPINVALUE}"
#echo "${EDBASEURIWITHPINSOURCE}"
#echo "${EDBASEURI}"
#echo "${EDPUBURI}"
#echo "${EDPRIURI}"
#echo "${EDCRTURI}"


title PARA "generate RSA key pair, self-signed certificate, remove public key"
KEYID='0005'
URIKEYID="%00%05"
TSTCRT="${TMPPDIR}/testcert2"
TSTCRTN="testCert2"

# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="RSA:2048" \
	--label="${TSTCRTN}" --id="$KEYID"
ca_sign "$TSTCRT" $TSTCRTN "My Test Cert 2" $KEYID
# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --delete-object --type pubkey --id 0005

BASE2URIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
BASE2URIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=${PINFILE}"
BASE2URI="pkcs11:id=${URIKEYID}"
PRI2URI="pkcs11:type=private;id=${URIKEYID}"
CRT2URI="pkcs11:type=cert;object=${TSTCRTN}"

title LINE "RSA2 PKCS11 URIS"
echo "${BASE2URIWITHPINVALUE}"
echo "${BASE2URIWITHPINSOURCE}"
echo "${BASE2URI}"
echo "${PRI2URI}"
echo "${CRT2URI}"
echo ""

title PARA "generate EC key pair, self-signed certificate, remove public key"
KEYID='0006'
URIKEYID="%00%06"
TSTCRT="${TMPPDIR}/eccert2"
TSTCRTN="ecCert2"

# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="EC:secp384r1" \
	--label="${TSTCRTN}" --id="$KEYID"
ca_sign "$TSTCRT" $TSTCRTN "My EC Cert 2" $KEYID
# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} --delete-object --type pubkey --id 0006

ECBASE2URIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
ECBASE2URIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file${PINFILE}"
ECBASE2URI="pkcs11:id=${URIKEYID}"
ECPRI2URI="pkcs11:type=private;id=${URIKEYID}"
ECCRT2URI="pkcs11:type=cert;object=${TSTCRTN}"

title LINE "EC2 PKCS11 URIS"
echo "${ECBASE2URIWITHPINVALUE}"
echo "${ECBASE2URIWITHPINSOURCE}"
echo "${ECBASE2URI}"
echo "${ECPRI2URI}"
echo "${ECCRT2URI}"
echo ""

if [ -f /etc/redhat-release ]; then
    title PARA "explicit EC unsupported on Fedora/EL"
else
    title PARA "generate explicit EC key pair"
    KEYID='0007'
    URIKEYID="%00%07"
    ECXCRTN="ecExplicitCert"

# shellcheck disable=SC2086
    pkcs11-tool ${P11DEFARGS} --write-object="${TESTSSRCDIR}/explicit_ec.key.der" --type=privkey \
        --label="${ECXCRTN}" --id="$KEYID"
# shellcheck disable=SC2086
    pkcs11-tool ${P11DEFARGS} --write-object="${TESTSSRCDIR}/explicit_ec.pub.der" --type=pubkey \
        --label="${ECXCRTN}" --id="$KEYID"

    ECXBASEURIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
    ECXBASEURIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file:${PINFILE}"
    ECXBASEURI="pkcs11:id=${URIKEYID}"
    ECXPUBURI="pkcs11:type=public;id=${URIKEYID}"
    ECXPRIURI="pkcs11:type=private;id=${URIKEYID}"

    title LINE "EXPLICIT EC PKCS11 URIS"
    echo "${ECXBASEURI}"
    echo "${ECXPUBURI}"
    echo "${ECXPRIURI}"
    echo ""
fi

# TODO: ALWAYS_AUTHENTICATE behavior not supported yet
#title PARA "generate EC key pair with ALWAYS AUTHENTICATE flag, self-signed certificate"
#KEYID='0008'
#URIKEYID="%00%08"
#TSTCRT="${TMPPDIR}/eccert3"
#TSTCRTN="ecCert3"
#
## shellcheck disable=SC2086
#pkcs11-tool ${P11DEFARGS} --keypairgen --key-type="EC:secp521r1" \
#	--label="${TSTCRTN}" --id="$KEYID" --always-auth
#ca_sign "$TSTCRT" $TSTCRTN "My EC Cert 3" $KEYID
#
#ECBASE3URIWITHPINVALUE="pkcs11:id=${URIKEYID}?pin-value=${PINVALUE}"
#ECBASE3URIWITHPINSOURCE="pkcs11:id=${URIKEYID}?pin-source=file:${PINFILE}"
#ECBASE3URI="pkcs11:id=${URIKEYID}"
#ECPUB3URI="pkcs11:type=public;id=${URIKEYID}"
#ECPRI3URI="pkcs11:type=private;id=${URIKEYID}"
#ECCRT3URI="pkcs11:type=cert;object=${TSTCRTN}"
#
#title LINE "EC3 PKCS11 URIS"
#echo "${ECBASE3URIWITHPINVALUE}"
#echo "${ECBASE3URIWITHPINSOURCE}"
#echo "${ECBASE3URI}"
#echo "${ECPUB3URI}"
#echo "${ECPRI3URI}"
#echo "${ECCRT3URI}"
#echo ""

title PARA "Show contents of kryoptic token"
echo " ----------------------------------------------------------------------------------------------------"
# shellcheck disable=SC2086
pkcs11-tool ${P11DEFARGS} -O
echo " ----------------------------------------------------------------------------------------------------"

title PARA "Output configurations"
OPENSSL_CONF=${TMPPDIR}/openssl.cnf

title LINE "Generate openssl config file"
sed -e "s|@libtoollibs@|${LIBSPATH}|g" \
    -e "s|@testsblddir@|${TESTBLDDIR}|g" \
    -e "s|@testsdir@|${TMPPDIR}|g" \
    -e "s|@SHARED_EXT@|${SHARED_EXT}|g" \
    -e "s|@PINFILE@|${PINFILE}|g" \
    -e "s|##QUIRKS|pkcs11-module-quirks = no-deinit|g" \
    -e "/pkcs11-module-init-args/d" \
    "${TESTSSRCDIR}/openssl.cnf.in" > "${OPENSSL_CONF}"

title LINE "Export test variables to ${TMPPDIR}/testvars"
cat >> "${TMPPDIR}/testvars" <<DBGSCRIPT
export P11LIB=${P11LIB}
export P11KITCLIENTPATH=${P11KITCLIENTPATH}
export PKCS11_PROVIDER_MODULE=${P11LIB}
export PKCS11_PROVIDER_DEBUG="file:${TMPPDIR}/p11prov-debug.log"
export OPENSSL_CONF="${OPENSSL_CONF}"
export KRYOPTIC_CONF="${TMPPDIR}/tokens/kryoptic.sql"
export TESTSSRCDIR="${TESTSSRCDIR}"
export TESTBLDDIR="${TESTBLDDIR}"

export TOKDIR="${TOKDIR}"
export TMPPDIR="${TMPPDIR}"
export PINVALUE="${PINVALUE}"
export SEEDFILE="${TMPPDIR}/noisefile.bin"
export RAND64FILE="${TMPPDIR}/64krandom.bin"

export BASEURIWITHPINVALUE="${BASEURIWITHPINVALUE}"
export BASEURIWITHPINSOURCE="${BASEURIWITHPINSOURCE}"
export BASEURI="${BASEURI}"
export PUBURI="${PUBURI}"
export PRIURI="${PRIURI}"
export CRTURI="${CRTURI}"

export ECBASEURIWITHPINVALUE="${ECBASEURIWITHPINVALUE}"
export ECBASEURIWITHPINSOURCE="${ECBASEURIWITHPINSOURCE}"
export ECBASEURI="${ECBASEURI}"
export ECPUBURI="${ECPUBURI}"
export ECPRIURI="${ECPRIURI}"
export ECCRTURI="${ECCRTURI}"

export ECPEERBASEURIWITHPINVALUE="${ECPEERBASEURIWITHPINVALUE}"
export ECPEERBASEURIWITHPINSOURCE="${ECPEERBASEURIWITHPINSOURCE}"
export ECPEERBASEURI="${ECPEERBASEURI}"
export ECPEERPUBURI="${ECPEERPUBURI}"
export ECPEERPRIURI="${ECPEERPRIURI}"
export ECPEERCRTURI="${ECPEERCRTURI}"

export BASE2URIWITHPINVALUE="${BASEURIWITHPINVALUE}"
export BASE2URIWITHPINSOURCE="${BASEURIWITHPINSOURCE}"
export BASE2URI="${BASE2URI}"
export PRI2URI="${PRI2URI}"
export CRT2URI="${CRT2URI}"

export ECBASE2URIWITHPINVALUE="${ECBASE2URIWITHPINVALUE}"
export ECBASE2URIWITHPINSOURCE="${ECBASE2URIWITHPINSOURCE}"
export ECBASE2URI="${ECBASE2URI}"
export ECPRI2URI="${ECPRI2URI}"
export ECCRT2URI="${ECCRT2URI}"
DBGSCRIPT

if [ -n "${ECXBASEURI}" ]; then
    cat >> "${TMPPDIR}/testvars" <<DBGSCRIPT

export ECXBASEURIWITHPINVALUE="${ECXBASEURIWITHPINVALUE}"
export ECXBASEURIWITHPINSOURCE="${ECXBASEURIWITHPINSOURCE}"
export ECXBASEURI="${ECXBASEURI}"
export ECXPUBURI="${ECXPUBURI}"
export ECXPRIURI="${ECXPRIURI}"
DBGSCRIPT
fi

cat >> "${TMPPDIR}/testvars" <<DBGSCRIPT

# for listing the separate pkcs11 calls
#export PKCS11SPY="${PKCS11_PROVIDER_MODULE}"
#export PKCS11_PROVIDER_MODULE=/usr/lib64/pkcs11-spy.so
DBGSCRIPT
gen_unsetvars

title ENDSECTION

