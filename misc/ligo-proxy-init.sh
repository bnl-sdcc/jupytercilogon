#!/bin/bash

# Setup environment
unset LD_LIBRARY_PATH
unset DYLD_LIBRARY_PATH
unset LD_PRELOAD
umask 077

usage()
{
cat << EOF
usage: `basename $0` [options] [username]

OPTIONS:
    -h                   Show this message
    -d                   Write debug output to stdout
    -v                   Write version information to stdout
    -i hostname          Use alternative IdP host e.g. login2.ligo.org
    -k                   Enable Kerberos negotiation. Do not provide username.
    -p                   Create RFC 3820 compliant impersonation proxy
    -H <h>               Proxy is valid for h hours [Default is $DEF_HOURS]
    -X                   Destroy proxy file

EXAMPLE:

`basename $0` albert.einstein
`basename $0` -k

EOF
}

# curl is required for sending to and from the SP and IdP
# xlstproc is required for gently massaging XML
# klist is required to check for valid kerberos ticket
# tempfile or mktemp is required for safe temporary files

type -P /usr/bin/curl >&/dev/null || { echo "This script requires curl. Aborting." >&2; exit 1; }
type -P /usr/bin/xsltproc >&/dev/null || { echo "This script requires xsltproc. Aborting." >&2; exit 1; }
type -P /usr/bin/openssl >&/dev/null || { echo "This script requires openssl. Aborting." >&2; exit 1; }

curl_command=/usr/bin/curl
xsltproc_command=/usr/bin/xsltproc
openssl_command=/usr/bin/openssl
klist_command=/usr/bin/klist

VERSION="1.3.3"

version()
{
cat << EOF
`basename $0` version $VERSION
EOF

echo
$curl_command --version
echo
$xsltproc_command -version
echo
$openssl_command version
echo
uname -a
echo

if [ -e /etc/issue ]
then
    cat /etc/issue
fi

}

destroy()
{
    if [ -e $proxy_file ] ; then
        if [ ! -f $proxy_file ]; then
            echo "ERROR: proxy file ${proxy_file} is not a regular file"
            exit 1
        fi

        rm -f $proxy_file
        ret=$?
        if [ $ret -ne 0 ] ; then
            echo "Not able to destroy proxy file ${proxy_file}"
            exit 1
        fi
    fi
}

# process command line

DEBUG=
VERBOSE="--silent"
OUTFILE=/dev/null
ERRFILE=/dev/null
CREATEPROXY=
# Set default certificate lifetime to ~11.5 hours corresponding
# to IGTF reccomendation for short lived certificates
DEF_HOURS=277

target_host=ecp.cilogon.org
target=https://${target_host}/secure/getcert/

connect_timeout=20
max_time=45
network_target=http://www.google.com

# write the proxy file to X509_USER_PROXY if set or to the default
# location
if [ -n "$X509_USER_PROXY" ]
then
    proxy_file=$X509_USER_PROXY
else
    uid=`id -u`
    proxy_file="/tmp/x509up_u$uid"
fi


while getopts ":hdpkvH:Xi:" OPTION
do
    case $OPTION in
        h)
          usage
          exit 0
          ;;
        d)
          version
          DEBUG=1
          VERBOSE="--verbose"
          OUTFILE=/dev/stdout
          ERRFILE=/dev/stderr
          ;;
        k)
         LIGOPROXYINIT_USE_KERBEROS=1
          ;;
        p)
	  grid_proxy_init_cmd=`type -P grid-proxy-init` || { echo "This option requires grid-proxy-init. Aborting." >&2; exit 1; }
	  CREATEPROXY=1
          ;;
        H)
	  HOURS=${OPTARG}
	  ( [[ "$HOURS" =~ ^[0-9]+$ ]] && [ "$HOURS" -gt 0 ] ) || { echo "Hours must be a number greater than 0. Aborting." >&2; exit 1; }
          ;;
        v)
          version
          exit 0
          ;;
        X)
          destroy
          exit 0
          ;;
        i)
          idp_hosts=${idp_hosts}" "${OPTARG}
          ;;
        :)
          echo "Option -$OPTARG requires an argument." >&2
          exit 1
	  echo "PLOP"
          ;;
    esac
done

: ${idp_hosts:="login.ligo.org login2.ligo.org"}
: ${HOURS:="$DEF_HOURS"}

shift $((OPTIND - 1))

if [ -n "${LIGOPROXYINIT_USE_KERBEROS}" ] ; then
    $curl_command -V | grep -Eq "(GSS-Negotiate|SPNEGO)"
    if [ $? -ne 0 ]; then
        echo "Kerberos authentication requires a curl library built with GSSAPI support."
        echo "Please use password authentication."
        exit 1
    fi

    if [ $# -ne 0 ]; then
        usage
        exit 1
    fi

    $klist_command -s 2> $ERRFILE && klist_output=$($klist_command 2> $ERRFILE)
    ret=$?

    if [ -n "$DEBUG" ]
    then
        echo
        echo "###### BEGIN KLIST OUTPUT"
        echo
        echo "$klist_output"
        echo
        echo "###### END KLIST OUTPUT"
        echo
    fi

    if [ $ret -ne 0 ] ; then
      echo "klist command failed. Please ensure you have a valid Kerberos ticket"
      echo "or use password authentication."
      echo
      echo "Return value was $ret."
      echo
      echo "Email rt-auth@ligo.org with the output above for help."
      exit 1
    fi

    principal=$(echo "$klist_output" | grep -im 1 "principal" | awk '{print $NF}')
    login=$(echo $principal | awk -F '@' '{ print $1 }' )
    curl_auth_method="--negotiate --user :"
    echo "Your identity: $principal"
else
    if [ $# -ne 1 ]; then
        usage
        exit 1
    fi

    login=${1/@*/}
    [[ $login == *","* ]] && echo "Replacing comma characters in login!"; login=${login//,/.}
    curl_auth_method="--user $login"
    echo "Your identity: $login@LIGO.ORG"
fi

if [ -w "/dev/shm" ]; then
    : ${TMPDIR:=/dev/shm}
fi

# either tempfile or mktemp is required for creating and managing temp files
temp_file_command=`type -P tempfile`
if [ ! $temp_file_command ] ; then
    temp_file_command=`type -P mktemp`
    if [ ! $temp_file_command ] ; then
        echo "This script requires tempfile or mktemp. Aborting." >&2
        exit 1
    else
        temp_file_maker="$temp_file_command /tmp/ligo_proxy_init.XXXXXX"
    fi
else
    temp_file_maker=$temp_file_command
fi

shredder="rm -f"

# some utility functionality for deleting temporary files
declare -a on_exit_items

function on_exit()
{
    for i in "${on_exit_items[@]}"
    do
        eval $i
    done
}

function add_on_exit()
{
    local n=${#on_exit_items[*]}
    on_exit_items[$n]="$*"
    if [[ $n -eq 0 ]]; then
        trap on_exit EXIT
    fi
}

function check_lscligolab_user()
{
    $curl_command -V | grep -Eq "(ldap)"
    if [ $? -ne 0 ]; then
	echo "You version of curl does not support LDAP. Skipping user validity check."
	return
    fi

    ldap_url=ldap://ldap.ligo.org:80/ou=people,dc=ligo,dc=org
    ldap_lscvirgo_community=Communities:LSCVirgoLIGOGroupMembers
    ldap_filter="(&(uid=$login)(isMemberOf=$ldap_lscvirgo_community))"
    search_res=`$curl_command --connect-timeout $connect_timeout -m $max_time $VERBOSE -B $ldap_url?DN?one?$ldap_filter 2>$ERRFILE`

    ret=$?
    if [ $ret -eq 0 ]
    then
	if [ -n "$DEBUG" ]
	then
            echo
            echo "###### BEGIN CURL LDAP RESULT"
            echo
            echo $search_res
            echo
            echo "###### END CURL LDAP RESULT"
            echo
	fi

        if [ ! "$search_res" ] ; then
            echo
            echo "Please check your username is entered correctly, and that you are a member of"
            echo "LSC, LIGOLab or Virgo."
            echo "If you still experience problems please email rt-auth@ligo.org for help."
            echo

            exit 12
        fi
   else
	if [ -n "$DEBUG" ]
	then
            echo
            echo "Warning: Error encountered while running LDAP lookup to perform user validity check."
            echo "Return value was $ret."
            echo
            echo "Proceeding to download certificate..."
            echo
	fi

    fi
}

# create a file curl can use to save session cookies
cookie_file=`$temp_file_maker`
add_on_exit $shredder $cookie_file

# headers needed for ECP
header_accept="Accept:text/html; application/vnd.paos+xml"
header_paos="PAOS:ver=\"urn:liberty:paos:2003-08\";\"urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp\""

# request the target from the SP and include headers signalling ECP
sp_resp=`$curl_command $VERBOSE -c $cookie_file -b $cookie_file -H "$header_accept" -H "$header_paos" "$target"`
ret=$?

if [ $ret -ne 0 ]
then
    echo "First curl GET of $target failed."
    echo "Return value was $ret."

    if [ $ret -eq 6 ] || [ $ret -eq 7 ]; then
        echo -n "This suggests a network error. "

	network_test_response=`curl --fail -s "${network_target}"`
	ret=$?
	if [ $ret -ne 0 ] ; then
	    echo -n "Also failed to connect to ${network_target/*\//}. "
	fi

	echo "Please check your network connection."
    fi
    echo
    echo "Email rt-auth@ligo.org with the output above for help."

    my_ligo_response=`curl --fail -s "${network_target}"`
    ret=$?
    if [ $ret -ne 0 ] ; then
        echo "Failed to connect to ${network_target/*\//}. Please check your network connection."
    fi

    exit 1
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN SP RESPONSE"
    echo
    echo $sp_resp
    echo
    echo "###### END SP RESPONSE"
    echo
fi

# craft the request to the IdP by using xsltproc
# and a stylesheet to remove the SOAP header
# but leave everything else

stylesheet_remove_header=`$temp_file_maker`
add_on_exit $shredder $stylesheet_remove_header

cat >> $stylesheet_remove_header <<EOF
<xsl:stylesheet version="1.0"
 xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
 xmlns:S="http://schemas.xmlsoap.org/soap/envelope/" >

 <xsl:output omit-xml-declaration="yes"/>

    <xsl:template match="node()|@*">
      <xsl:copy>
         <xsl:apply-templates select="node()|@*"/>
      </xsl:copy>
    </xsl:template>

    <xsl:template match="S:Header" />

</xsl:stylesheet>
EOF

idp_request=`echo "$sp_resp" | $xsltproc_command $stylesheet_remove_header -`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Parse error from xsltproc on first curl GET of $target."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 2
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN IDP REQUEST"
    echo
    echo $idp_request
    echo
    echo "###### END IDP REQUEST"
    echo
fi

# pick out the relay state element from the SP response
# so that it can later be included in the package to the SP

stylesheet_get_relay_state=`$temp_file_maker`
add_on_exit $shredder $stylesheet_get_relay_state

cat >> $stylesheet_get_relay_state <<EOF
<xsl:stylesheet version="1.0"
 xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
 xmlns:ecp="urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp"
 xmlns:S="http://schemas.xmlsoap.org/soap/envelope/" >

 <xsl:output omit-xml-declaration="yes"/>

 <xsl:template match="/">
     <xsl:copy-of select="//ecp:RelayState" />
 </xsl:template>

</xsl:stylesheet>
EOF

relay_state=`echo "$sp_resp" | $xsltproc_command $stylesheet_get_relay_state -`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Parse error from xsltproc for relay state element."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 3
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN RELAY STATE ELEMENT"
    echo
    echo $relay_state
    echo
    echo "###### END RELAY STATE ELEMENT"
    echo
fi

# pick out the responseConsumerURL attribute value from the SP response
# so that it can later be compared to the assertionConsumerURL sent from
# the IdP

stylesheet_get_responseConsumerURL=`$temp_file_maker`
add_on_exit $shredder $stylesheet_get_responseConsumerURL

cat >> $stylesheet_get_responseConsumerURL <<EOF
<xsl:stylesheet version="1.0"
 xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
 xmlns:ecp="urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp"
 xmlns:S="http://schemas.xmlsoap.org/soap/envelope/"
 xmlns:paos="urn:liberty:paos:2003-08" >

 <xsl:output omit-xml-declaration="yes"/>

 <xsl:template match="/">
     <xsl:value-of select="/S:Envelope/S:Header/paos:Request/@responseConsumerURL" />
 </xsl:template>

</xsl:stylesheet>
EOF

responseConsumerURL=`echo "$sp_resp" | $xsltproc_command $stylesheet_get_responseConsumerURL -`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Parse error from xsltproc for consumer URL."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 4
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN RESPONSE CONSUMER URL"
    echo
    echo $responseConsumerURL
    echo
    echo "###### END RESPONSE CONSUMER URL"
    echo
fi


for idp_host in $idp_hosts; do
    idp_endpoint=https://${idp_host}/idp/profile/SAML2/SOAP/ECP
    if [ -n "$DEBUG" ] || [ -n "$report_idp" ]; then
        echo Attempting connection to $idp_endpoint
    fi

    if [ -z "${LIGOPROXYINIT_USE_KERBEROS}" ]; then
        echo -n "Enter pass phrase for this identity:"
    fi

    # use curl to POST the request to the IdP
    # and use the login supplied by the user, prompting for a password
    idp_response=`$curl_command $VERBOSE --fail --connect-timeout $connect_timeout -m $max_time -X POST -H 'Content-Type: text/xml; charset=utf-8' -c $cookie_file -b $cookie_file $curl_auth_method -d "$idp_request" $idp_endpoint 2> $ERRFILE`

    ret=$?
    echo
    if [ $ret -eq 0 ] ; then break; fi

    echo
    echo "curl POST to IdP at endpoint $idp_endpoint failed. Error code ${ret}"
    echo

    if [ ! -n "${LIGOPROXYINIT_USE_KERBEROS}" ]; then
        echo "You most likely incorrectly entered your passphrase."
        echo
    else
        echo "Please ensure that you have a valid Kerberos ticket"
        echo
    fi

    report_idp=true
done

if [ $ret -ne 0 ]
then
    check_lscligolab_user

    echo "If this error persists please email rt-auth@ligo.org"
    echo "with the output above for help."
    echo
    exit 1
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN IDP RESPONSE"
    echo
    echo $idp_response
    echo
    echo "###### END IDP RESPONSE"
    echo
fi

# signal to user that authentication worked and we are now proceeding
echo -n "Creating proxy .................................... "

# use xlstproc to pick out the assertion consumer service URL
# from the response sent by the IdP

stylesheet_assertion_consumer_service_url=`$temp_file_maker`
add_on_exit $shredder $stylesheet_assertion_consumer_service_url

cat >> $stylesheet_assertion_consumer_service_url <<EOF
<xsl:stylesheet version="1.0"
 xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
 xmlns:ecp="urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp"
 xmlns:S="http://schemas.xmlsoap.org/soap/envelope/" >

 <xsl:output omit-xml-declaration="yes"/>

 <xsl:template match="/">
     <xsl:value-of select="S:Envelope/S:Header/ecp:Response/@AssertionConsumerServiceURL" />
 </xsl:template>

</xsl:stylesheet>
EOF

assertionConsumerServiceURL=`echo "$idp_response" | $xsltproc_command $stylesheet_assertion_consumer_service_url -`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Parse error from xsltproc for ACS URL."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 6
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN ASSERTION CONSUMER SERVICE URL"
    echo
    echo $assertionConsumerServiceURL
    echo
    echo "###### END ASSERTION CONSUMER SERVICE URL"
    echo
fi

# compare the responseConsumerURL from the SP to the
# assertionConsumerServiceURL from the IdP and if they
# are not identical then send a SOAP fault to the SP

if [ "$responseConsumerURL" != "$assertionConsumerServiceURL" ]
then

echo "ERROR: assertionConsumerServiceURL $assertionConsumerServiceURL does not"
echo "match responseConsumerURL $responseConsumerURL"
echo "sending SOAP fault to SP"
echo
echo "Email rt-auth@ligo.org with the output above for help."

read -d '' soap_fault <<"EOF"
<S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/">
   <S:Body>
     <S:Fault>
       <faultcode>S:Server</faultcode>
       <faultstring>responseConsumerURL from SP and assertionConsumerServiceURL from IdP do not match</faultstring>
     </S:Fault>
   </S:Body>
</S:Envelope>
EOF

$curl_command $VERBOSE -X POST -c $cookie_file -b $cookie_file -d "$soap_fault" -H "Content-Type: application/vnd.paos+xml" $responseConsumerURL 1> $OUTFILE 2> $ERRFILE

exit 7

fi

# craft the package to send to the SP by
# copying the response from the IdP but removing the SOAP header
# sent by the IdP and instead putting in a new header that
# includes the relay state sent by the SP

stylesheet_sp_package=`$temp_file_maker`
add_on_exit $shredder $stylesheet_sp_package

cat >> $stylesheet_sp_package <<EOF
<xsl:stylesheet version="1.0"
 xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
 xmlns:soap11="http://schemas.xmlsoap.org/soap/envelope/" >

 <xsl:output omit-xml-declaration="no" encoding="UTF-8"/>

    <xsl:template match="node()|@*">
      <xsl:copy>
         <xsl:apply-templates select="node()|@*"/>
      </xsl:copy>
    </xsl:template>

    <xsl:template match="soap11:Header" >
        <soap11:Header>$relay_state</soap11:Header>
    </xsl:template>

</xsl:stylesheet>
EOF

sp_package=`echo "$idp_response" | $xsltproc_command $stylesheet_sp_package -`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Parse error from xsltproc for SP package."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 8
fi

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN PACKAGE TO SEND TO SP"
    echo
    echo $sp_package
    echo
    echo "###### END PACKAGE TO SEND TO SP"
    echo
fi

# push the response to the SP at the assertion consumer service
# URL included in the response from the IdP

$curl_command $VERBOSE -c $cookie_file -b $cookie_file -X POST -d "$sp_package" -H "Content-Type: application/vnd.paos+xml" $assertionConsumerServiceURL 1> $OUTFILE 2> $ERRFILE

ret=$?
if [ $ret -ne 0 ]
then
    echo "Second curl POST to SP failed."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 9
fi

# create a new certreq and write a new private key
private_key_file=`$temp_file_maker`
add_on_exit $shredder $private_key_file
mycsr=`$openssl_command req -new -newkey rsa:2048 -keyout $private_key_file -nodes -subj "/CN=ignore" 2>/dev/null`

ret=$?

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN CSR"
    echo
    echo $mycsr
    echo
    echo "###### END CSR"
    echo
fi

if [ $ret -ne 0 ]
then
    echo "Generation of certificate request and key failed."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 10
fi

# generate a random string for the CSRF value
# that will work both as a cookie value and as
# part of the POST
csrf_string=`$openssl_command rand -hex 10`

ret=$?
if [ $ret -ne 0 ]
then
    echo "Generation of CSRF value failed."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 11
fi

# add the CSRF cookie to the cookie_file
echo "$target_host	FALSE	/	TRUE	0	CSRF	$csrf_string" >> $cookie_file

# get a certificate using a certreq and write it to a temporary file
cert_file=`$temp_file_maker`
add_on_exit $shredder $cert_file
$curl_command $VERBOSE -f --connect-timeout $connect_timeout -m $max_time -F "submit=certreq" -F "certreq=$mycsr" -F "certlifetime=${HOURS}" -F "CSRF=$csrf_string" -c $cookie_file -b $cookie_file -X POST "$target" -o "$cert_file"

ret=$?

if [ -n "$DEBUG" ]
then
    echo
    echo "###### BEGIN CERTIFICATE"
    echo
    cat $cert_file
    echo
    echo "###### END CERTIFICATE"
    echo
fi

if [ $ret -ne 0 ]
then
    echo "Failed to retrieve signed certificate."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 12
fi

# sanity check the returned certificate
$openssl_command x509 -noout -text -in $cert_file 1> $OUTFILE 2> $ERRFILE

ret=$?
if [ $ret -ne 0 ]
then
    echo "There is a problem with the signed certificate."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 13
fi

# communicate to user we now have signed certificate
echo "Done"

# use signed certificate and private key to create a "proxy" file

# delete the contents of the old proxy file
rm -f $proxy_file 1> $OUTFILE 2> $ERRFILE

ret=$?
if [ $ret -ne 0 ]
then
    echo "Failed to delete old proxy certificate file."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 14
fi

# copy the contents of the certificate to the proxy file
cp $cert_file $proxy_file

ret=$?
if [ $ret -ne 0 ]
then
    echo "Failed to copy certificate file to proxy certificate file."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 15
fi

# protect the proxy file with permissions 0600
chmod 600 $proxy_file

ret=$?
if [ $ret -ne 0 ]
then
    echo "Failed to set permissions proxy certificate file."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 16
fi

# copy the private key into the proxy file
echo -e "\n" >> $proxy_file
cat $private_key_file >> $proxy_file

ret=$?
if [ $ret -ne 0 ]
then
    echo "Failed to create proxy certificate file."
    echo "Return value was $ret."
    echo
    echo "Email rt-auth@ligo.org with the output above for help."
    exit 17
fi

if [ $CREATEPROXY ]; then
    $grid_proxy_init_cmd -valid ${HOURS}:00 -cert $proxy_file -key $proxy_file 1> $OUTFILE 2> $ERRFILE

    ret=$?
    if [ $ret -ne 0 ]
    then
	echo "Failed to create proxy certificate file."
	echo "Return value was $ret."
	echo
	echo "Please email rt-auth@ligo.org with the output above for help."
	exit 18
    fi
fi

# final communication to user about valid until
enddate=`$openssl_command x509 -noout -enddate -in $proxy_file`

echo -n "Your proxy is valid until: "
echo ${enddate:9:${#enddate}}

exit 0
