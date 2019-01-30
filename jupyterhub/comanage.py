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




class NormalizingLocalAuthenticator(LocalAuthenticator):
    '''
    Creates local UNIX username from COManage/CILogon eppn. 
    
    
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
        unixname = user.name.replace('@','')
        unixname = unixname.replace('.','')
        user.unixname = unixname
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
        #name = user.name
        name = user.unixname
        cmd = [ arg.replace('USERNAME', name) for arg in self.add_user_cmd ] + [name]
        self.log.info("Creating user: %s", ' '.join(map(pipes.quote, cmd)))
        p = Popen(cmd, stdout=PIPE, stderr=STDOUT)
        p.wait()
        if p.returncode:
            err = p.stdout.read().decode('utf8', 'replace')
            raise RuntimeError("Failed to create system user %s: %s" % (name, err))








class NormalizedLocalProcessSpawner(LocalProcessSpawner):

    def user_env(self, env):
        """Augment environment of spawned process with user specific env variables."""
        import pwd
        unixname = self.user.name.replace('@','')
        unixname = unixname.replace('.','')
        #env['USER'] = self.user.name
        env['USER'] = unixname
        #home = pwd.getpwnam(self.user.name).pw_dir
        home = pwd.getpwnam(unixname).pw_dir
        #shell = pwd.getpwnam(self.user.name).pw_shell
        shell = pwd.getpwnam(unixname).pw_shell
        # These will be empty if undefined,
        # in which case don't set the env:
        if home:
            env['HOME'] = home
        if shell:
            env['SHELL'] = shell
        return env

    async def start(self):
        """Start the single-user server."""
        self.port = random_port()
        cmd = []
        env = self.get_env()

        cmd.extend(self.cmd)
        cmd.extend(self.get_args())

        if self.shell_cmd:
            # using shell_cmd (e.g. bash -c),
            # add our cmd list as the last (single) argument:
            cmd = self.shell_cmd + [' '.join(pipes.quote(s) for s in cmd)]

        self.log.info("Spawning %s", ' '.join(pipes.quote(s) for s in cmd))
        unixname = self.user.name.replace('@','')
        unixname = unixname.replace('.','')
        popen_kwargs = dict(
            #preexec_fn=self.make_preexec_fn(self.user.name),
            preexec_fn=self.make_preexec_fn(unixname),
            start_new_session=True,  # don't forward signals
        )
        popen_kwargs.update(self.popen_kwargs)
        # don't let user config override env
        popen_kwargs['env'] = env
        try:
            self.proc = Popen(cmd, **popen_kwargs)
        except PermissionError:
            # use which to get abspath
            script = shutil.which(cmd[0]) or cmd[0]
            self.log.error("Permission denied trying to run %r. Does %s have access to this file?",
                #script, self.user.name,
                script, self.user.unixname,
            )
            raise

        self.pid = self.proc.pid

        if self.__class__ is not LocalProcessSpawner:
            # subclasses may not pass through return value of super().start,
            # relying on deprecated 0.6 way of setting ip, port,
            # so keep a redundant copy here for now.
            # A deprecation warning will be shown if the subclass
            # does not return ip, port.
            if self.ip:
                self.server.ip = self.ip
            self.server.port = self.port
            self.db.commit()
        return (self.ip or '127.0.0.1', self.port)

class NormalizedSpawner(Spawner):

    @property
    def _log_name(self):
        """Return username:servername or username

        Used in logging for consistency with named servers.
        """
        if self.name:
            #return '%s:%s' % (self.user.name, self.name)
            return '%s:%s' % (self.user.unixname, self.name)
        else:
            #return self.user.name
            return self.user.unixname