#!/usr/bin/python

import urllib, urllib2, cookielib, sys

# Set up the username and password we'll use to log in
username = ''
password = ''
if len(sys.argv) > 1:
	idp = sys.argv[1]
	sp  = sys.argv[2]
	endpoint = sys.argv[3]
else:
        # Default to prod
	idp = 'login.anl.gov'
	sp  = 'shib-sp-dev0.it.anl.gov'
	endpoint = '/protected.prod.nods'

# Initialize a place to put the Shibboleth login cookie
cj = cookielib.CookieJar()

# Construct an opener bound to our cookiejar
opener = urllib2.build_opener(urllib2.HTTPCookieProcessor(cj))

# Build the POST request
login_data = urllib.urlencode({'j_username' : username, 'j_password' : password})

# Check to see if we can talk to the IdP
try:
	resp = opener.open('https://'+idp+'/idp/Authn/UserPassword', login_data)
except urllib2.HTTPError as detail:
	#print 'Returned Status: 2'
	print 'Unable to connect to idp: ' + idp 
	print detail
	sys.exit(2)

#resp = opener.open('https://'+idp+'/idp/Authn/UserPassword', login_data)
content = resp.read()

# Check to see if we were able to talk to the IdP, but the creds
# were rejected
if content.find("Credentials not recognized") > 0:
	#print 'Returned Status: 2'
	print 'IDP Said credentials were invalid! (error connecting to AD?)'
  	sys.exit(2)

# Check to see if we can talk to the SP
try:
	opener.open('https://'+sp+endpoint)
except urllib2.HTTPError as detail:
	#print 'Returned Status: 1'
	print 'Unable to connect to SP: ' + sp + endpoint
	print detail
	sys.exit(1)

# Once we verify we can talk to the SP and the IDP we need to do it all 
# again because try/catch breaks the cookiejar

# This connect attempt will populate the CookieJar with a valid Shibboleth 
# Cookie
opener.open('https://'+idp+'/idp/Authn/UserPassword', login_data)

# Retrieve the encrypted SAML assertion
resp = opener.open('https://'+sp+endpoint)
content = resp.read()
resp_array = content.split('"')

# The value of this should be "SAMLResponse":
form_attrib = resp_array[19]
# The value of this should be a long encoded string:
form_data = resp_array[21]

# Construct the POST
saml = urllib.urlencode({form_attrib:form_data})

# Try and POST the assertion to the SP
try:
	resp = opener.open('https://'+sp+'/Shibboleth.sso/SAML2/POST', saml)
except urllib2.HTTPError as detail:
	#print 'Returned Status: 3'
	print 'Unable to POST SAML2 Assertion:' 
	print detail
	sys.exit(3)

# Attempt to acess a shibboleth-protected page
try:
	resp = opener.open('https://'+sp+endpoint)
except urllib2.HTTPError as detail:
	#print 'Returned Status: 1'
	print 'Unable to connect to SP: ' + sp 
	print detail
	sys.exit(1)

content = resp.read()

# Did we get in?
if content.find("<h1>Shibboleth protected test page</h1>") > 0:
	#print 'Returned Status: 0'
	print 'HEALTH_OK'
	sys.exit(0)
else:
	#print 'Returned status: 2'
	print 'Unable to access Shibboleth Protected Page!'
	sys.exit(2)
