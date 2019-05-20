# From spawner

import asyncio
import errno
import json
import os
import pipes
import shutil
import signal
import sys
import warnings
from subprocess import Popen
from tempfile import mkdtemp

# FIXME: remove when we drop Python 3.5 support
from async_generator import async_generator, yield_

from sqlalchemy import inspect

from tornado.ioloop import PeriodicCallback

from traitlets.config import LoggingConfigurable
from traitlets import (
    Any, Bool, Dict, Instance, Integer, Float, List, Unicode, Union,
    default, observe, validate,
)

from .objects import Server
from .traitlets import Command, ByteSpecification, Callable
from .utils import iterate_until, maybe_future, random_port, url_path_join, exponential_backoff

# From auth

from concurrent.futures import ThreadPoolExecutor
import pipes
import re
from shutil import which
import sys
from subprocess import Popen, PIPE, STDOUT

try:
    import pamela
except Exception as e:
    pamela = None
    _pamela_error = e

from tornado.concurrent import run_on_executor

from traitlets.config import LoggingConfigurable
from traitlets import Bool, Set, Unicode, Dict, Any, default, observe

from .handlers.login import LoginHandler
from .utils import maybe_future, url_path_join
from .traitlets import Command


from jupyterhub.auth import LocalAuthenticator
from jupyterhub.spawner import LocalProcessSpawner, Spawner



class COManageLocalAuthenticator(LocalAuthenticator):
    '''
    Creates local UNIX username from COManage/CILogon sources. 
    
    '''   
    @default('add_user_cmd')
    def _add_user_cmd_default(self):
        """Guess the most likely-to-work adduser command for each platform"""
        if sys.platform == 'darwin':
            raise ValueError("I don't know how to create users on OS X")
        elif which('pw'):
            # Probably BSD
            return ['pw', 'useradd', '-m']
        else:
            # This appears to be the Linux non-interactive adduser command:
            #return ['adduser', '-q', '--gecos', '""', '--disabled-password']
            return ['adduser', '-c', '"COManage User"']

    async def add_user(self, user):
        """Hook called whenever a new user is added

        If self.create_system_users, the user will attempt to be created if it doesn't exist.
        """
        user.unixname = self.get_mapped_unixname(user)
        user_exists = await maybe_future(self.system_user_exists(user))
        #user_exists = await maybe_future(self.system_user_exists(unixuser))
        if not user_exists:
            if self.create_system_users:
                await maybe_future(self.add_system_user(user))
            else:
                raise KeyError("User %s does not exist." % user.unixname)
                #raise KeyError("User %s does not exist." % unixuser)

        await maybe_future(super().add_user(user))

    @staticmethod
    def system_user_exists(user):
        """Check if the user exists on the system"""
        import pwd
        try:
            #pwd.getpwnam(user.name)
            pwd.getpwnam(user.unixname)
        except KeyError:
            return False
        else:
            return True

    def add_system_user(self, user):
        """Create a new local UNIX user on the system.

           Tested to work on FreeBSD and Linux, at least.
        """
        self.log.debug("add_system_user() called for %s of type %s " % (user, type(user)))
        name = self.get_mapped_unixname(user)
        cmd = [ arg.replace('USERNAME', name) for arg in self.add_user_cmd ] + [name]
        self.log.info("Creating user: %s", ' '.join(map(pipes.quote, cmd)))
        p = Popen(cmd, stdout=PIPE, stderr=STDOUT)
        p.wait()
        if p.returncode:
            err = p.stdout.read().decode('utf8', 'replace')
            raise RuntimeError("Failed to create system user %s: %s" % (name, err))


    def get_mapped_unixname(self, user):
        self.log.debug("Trying to map user %s" % user.name)
        unixname = None
        if self.unixname_source == 'eppn_normalized':
            unixname = user.name.replace('@','')
            unixname = unixname.replace('.','')           
        elif self.unixname_source == 'eppn_mapfile':
            try:
                unixname = self.match_eppn_mapfile(user)
                user.unixname = unixname
            except Exception as e:
                raise RuntimeError("Failed to map user %s %s " % (user.name, e))
        self.log.info("Mapped %s to %s" % (user.name, unixname))
        return unixname
 
            
    def match_eppn_mapfile(self, user):
        self.log.debug("Opening mapfile %s" % self.eppn_mapfile)
        f = open(self.eppn_mapfile)
        lines = f.readlines()
        f.close()
        self.log.debug("Filtering lines and making map...")
        goodlines = []
        usermap = {}
        for line in lines:
            if "#" in line:
                pass
            else:
                nline = line.strip()
                goodlines.append(nline)
        for line in goodlines:
            (username, unix) = line.split()
            usermap[username] = unix
        self.log.debug("Mapfile with %d entries." % len(usermap) )
        target = usermap[user.name]
        self.log.debug("Got target unix name %s without exception." % target)
        return target    
      



class COManageLocalProcessSpawner(LocalProcessSpawner):

    def user_env(self, env):
        """Augment environment of spawned process with user specific env variables."""
        import pwd

        env['USER'] = self.user.unixname
        home = pwd.getpwnam(self.user.unixname).pw_dir
        shell = pwd.getpwnam(self.user.unixname).pw_shell
        # These will be empty if undefined,
        # in which case don't set the env:
        if home:
            env['HOME'] = home
        if shell:
            env['SHELL'] = shell
        return env

    async def move_certs(self, paths):
        """Takes cert paths, moves and sets ownership for them

        Arguments:
            paths (dict): a list of paths for key, cert, and CA

        Returns:
            dict: a list (potentially altered) of paths for key, cert,
            and CA

        Stage certificates into a private home directory
        and make them readable by the user.
        """
        import pwd

        key = paths['keyfile']
        cert = paths['certfile']
        ca = paths['cafile']

        user = pwd.getpwnam(self.user.unixname)
        uid = user.pw_uid
        gid = user.pw_gid
        home = user.pw_dir

        # Create dir for user's certs wherever we're starting
        out_dir = "{home}/.jupyterhub/jupyterhub-certs".format(home=home)
        shutil.rmtree(out_dir, ignore_errors=True)
        os.makedirs(out_dir, 0o700, exist_ok=True)

        # Move certs to users dir
        shutil.move(paths['keyfile'], out_dir)
        shutil.move(paths['certfile'], out_dir)
        shutil.copy(paths['cafile'], out_dir)

        key = os.path.join(out_dir, os.path.basename(paths['keyfile']))
        cert = os.path.join(out_dir, os.path.basename(paths['certfile']))
        ca = os.path.join(out_dir, os.path.basename(paths['cafile']))

        # Set cert ownership to user
        for f in [out_dir, key, cert, ca]:
            shutil.chown(f, user=uid, group=gid)

        return {"keyfile": key, "certfile": cert, "cafile": ca}

   

        
        
