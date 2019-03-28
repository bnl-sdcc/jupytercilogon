#!/bin/bash
#Run a SAML authnRequest using curl

# You must set the following on the big-ip:
#  IDP_FQDN
# Set DEBUG=true if you need to see what's going on, check the $DEBUG_FILE for info

SAMLID="$(ID="$(head /dev/urandom | tr -dc A-Za-z0-9_- | head -c 26 )"; echo "_$ID")"
ISSUEINSTANT="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
SPID=${SPID:-https://healthcheck.anl.gov/SSO}
USERNAME=${USERNAME:-user}
PASSWORD=${PASSWORD:-pass}
IDP_FQDN=${IDP_FQDN:-login-dev.anl.gov}
DEBUG=${DEBUG:-false}


# BIG-IP feeds the ip and port as the first arg (::ffff:10.0.0.1:443), we need to strip the first and last parts to only get the IP
IP="$(echo ${1} | sed 's/::ffff://' | sed 's/:[0-9]\+$//')"
IDP_IP=${IDP_IP:-$IP}
DESTINATION=${DESTINATION:-https://$IDP_FQDN/idp/profile/SAML2/POST/SSO}

# Each pool member needs its own temp files
RESPONSE_HTML_FILE="/tmp/response_tmp_$IDP_IP.html"
RESPONSE_XML_FILE="/tmp/response_tmp_$IDP_IP.xml"
COOKIE_FILE="/tmp/cookie_$IDP_IP.txt"
DEBUG_FILE="/tmp/idp_check_debug_$IDP_IP.txt"

if [ $DEBUG == "true" ]
  then
    echo -e "$SAMLID\n$ISSUEINSTANT\n$SPID\n$USERNAME\n$PASSWORD\n$IDP_FQDN\n$DESTINATION" > $DEBUG_FILE
fi

# Build SAML AUTHN REQUEST
AUTHNREQUEST="<samlp:AuthnRequest Version=\"2.0\" ID=\"$SAMLID\" IssueInstant=\"$ISSUEINSTANT\" Destination=\"$DESTINATION\" xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\"><saml:Issuer xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\">$SPID</saml:Issuer><samlp:NameIDPolicy AllowCreate=\"true\"/></samlp:AuthnRequest>"

if [ $DEBUG == "true" ]
  then
    echo $AUTHNREQUEST >> $DEBUG_FILE
fi

ENCODED="$(echo $AUTHNREQUEST | base64 | tr -d '\n' | sed 's/\+/%2B/g')"

if [ $DEBUG == "true" ]
  then
    echo $ENCODED >> $DEBUG_FILE
fi

# Initiate SSO session as if you were sent from the SP
curl -ks  --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE --location -d "SAMLRequest=$ENCODED" -H "Host: $IDP_FQDN" https://$IDP_IP/idp/profile/SAML2/POST/SSO > $RESPONSE_HTML_FILE

# Check for failure, clean up and exit if so
if ! grep -qi 'j_username' $RESPONSE_HTML_FILE ; then
	if [ $DEBUG == "true" ] ; then
	    echo "Couldn't find password form" >> $DEBUG_FILE 
	fi
        rm $RESPONSE_HTML_FILE $RESPONSE_XML_FILE $COOKIE_FILE 2> /dev/null
	echo "Couldn't find password form"
	exit 1
fi

AUTH_URL="$(grep '<form ' $RESPONSE_HTML_FILE | egrep -o 'action="[a-zA-Z0-9;:?=./-]+"' | cut -d\" -f2 | head -n1)"

if [ $DEBUG == "true" ]
  then
    echo $AUTH_URL >> $DEBUG_FILE
fi

# If good, attempt to authenticate
curl -ks --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE --location -d "_eventId_proceed=---" -d "j_username=$USERNAME" -d "j_password=$PASSWORD" -H "Host: $IDP_FQDN" https://$IDP_IP$AUTH_URL > $RESPONSE_HTML_FILE

# Check for failure, if so cleanup and exit
if grep -qi '<div id="errorDiv" data-alert class="alert-box alert radius">' $RESPONSE_HTML_FILE ; then
	if [ $DEBUG == "true" ] ; then
	    ERROR="$(grep -A4 '<div id="errorDiv" data-alert class="alert-box alert radius">' $RESPONSE_HTML_FILE)"
	    echo $ERROR >> $DEBUG_FILE
        fi
        rm $RESPONSE_HTML_FILE $RESPONSE_XML_FILE $COOKIE_FILE 2> /dev/null
	echo "IDP login page presented an error"
	exit 1
fi

grep SAMLResponse $RESPONSE_HTML_FILE | egrep -o 'value="[a-zA-Z0-9=+/]+"' | cut -d\" -f2 | base64 -d 2>/dev/null | xmllint --format - > $RESPONSE_XML_FILE

# Check for failure, if so cleanup and exit
if ! grep -qi 'urn:oasis:names:tc:SAML:2.0:status:Success' $RESPONSE_XML_FILE ; then
	if [ $DEBUG == "true" ] ; then
       	    echo "Couldn't find SAML success message in response" >> $DEBUG_FILE
	fi
        rm $RESPONSE_HTML_FILE $RESPONSE_XML_FILE $COOKIE_FILE 2> /dev/null
       	echo "Couldn't find SAML success message in response" 
	exit 1
fi

# Clean up: logout from the session and delete temp files
#curl -ks --cookie $COOKIE_FILE --cookie-jar $COOKIE_FILE --location -H "Host: $IDP_FQDN" https://$IDP_IP/idp/profile/Logout > $RESPONSE_HTML_FILE
rm $RESPONSE_HTML_FILE $RESPONSE_XML_FILE $COOKIE_FILE 2> /dev/null

# Let big-ip know the health check passed
echo "HEALTH_OK|"
