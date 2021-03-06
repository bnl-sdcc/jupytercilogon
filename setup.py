#
# Basic setup file for pip install
#

import sys
from setuptools import setup, find_packages

setup(
    name="pycomanage",
    version='0.95',
    description='Libraries and utilities for COManage/CILogon usage.',
    long_description='''Libraries and utilities for COManage/CILogon usage.''',
    license='BSD',
    author='John Hover',
    author_email='jhover@bnl.gov',
    url='https://github.com/bnl-sdcc/pycomanage',
    #python_requires='>=2.7',
    packages=[ 'oauthenticator',
               'jupyterhub'
               ],
    install_requires=[],
    data_files=[
        # config and cron files
        ('etc', [ 'etc/pycomanage.conf' ]
         ),
        ('etc/jupyterhub', ['etc/jupyterhub_config_comanage.py']
         ),        
        ],
    )


