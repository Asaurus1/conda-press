"""Tools for representing wheels in-memory"""
import os
import re
import sys
import base64
from hashlib import sha256
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
from collections import defaultdict
from collections.abc import Sequence, MutableSequence

from tqdm import tqdm
from lazyasd import lazyobject

from conda_press import __version__ as VERSION


DYNAMIC_SP_UNIX_PROXY_SCRIPT = """#!/bin/bash
current_dir="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" >/dev/null 2>&1 && pwd )"
declare -a targets
targets=$(echo "${{current_dir}}"/../lib/python*/site-packages/bin/{basename})
exec "${{targets[0]}}" "$@"
"""
DYNAMIC_SP_PY_UNIX_PROXY_SCRIPT = """#!/bin/bash
current_dir="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" >/dev/null 2>&1 && pwd )"
declare -a targets
targets=$(echo "${{current_dir}}"/../lib/python*/site-packages/bin/{basename})
exec "${{current_dir}}/python" "${{targets[0]}}" "$@"
"""
KNOWN_SP_UNIX_PROXY_SCRIPT = """#!/bin/bash
current_dir="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" >/dev/null 2>&1 && pwd )"
exec "${{current_dir}}/../lib/python{pymajor}.{pyminor}/site-packages/bin/{basename}" "$@"
"""
KNOWN_SP_PY_UNIX_PROXY_SCRIPT = """#!/bin/bash
current_dir="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" >/dev/null 2>&1 && pwd )"
exec "${{current_dir}}/python{pymajor}.{pyminor}" "${{current_dir}}/../lib/python{pymajor}.{pyminor}/site-packages/bin/{basename}" "$@"
"""
WIN_PROXY_SCRIPT = """@echo off
call "%~dp0\\\\..\\\\Lib\\\\site-packages\\\\{path_to_exe}\\\\{basename}" %*
exit /B %ERRORLEVEL%
"""

WIN_EXE_WEIGHTS = defaultdict(int, {
    ".com": 1,
    ".bat": 2,
    ".cmd": 3,
    ".exe": 4,
})

@lazyobject
def re_python_ver():
    return re.compile(r'^[cp]y(\d)(\d)$')


def urlsafe_b64encode_nopad(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def urlsafe_b64decode_nopad(data):
    pad = b'=' * (4 - (len(data) & 3))
    return base64.urlsafe_b64decode(data + pad)


def record_hash(data):
    dig = sha256(data).digest()
    b64 = urlsafe_b64encode_nopad(dig)
    return 'sha256=' + b64.decode('utf8')


def _normalize_path_mappings(value, basedir, arcbase='.'):
    # try to operate in place if we can.
    if isinstance(value, Sequence) and not isinstance(value, MutableSequence):
        value = list(value)
    elif isinstance(value, MutableSequence):
        pass
    else:
        raise TypeError(f'cannot convert pathlist, wrong type for {value!r}')
    # make sure base dir is a path
    if basedir is None:
        raise TypeError('basedir must be a str, cannot be None')
    # make alterations and return
    for i in range(len(value)):
        elem = value[i]
        if isinstance(elem, str):
            fsname = arcname = elem
            norm_arcname = True
        elif isinstance(elem, Sequence) and len(elem) == 2:
            fsname, arcname = elem
            norm_arcname = False
        else:
            raise TypeError(f'{elem!r} (value[{i}]) has the wrong type')
        # normalize fsname
        if os.path.isabs(fsname):
            fsname = os.path.relpath(fname, basedir)
        # normalize arcpath
        if norm_arcname:
            if arcbase == '.':
                arcname = fsname
            else:
                arcname = os.path.join(arcbase, os.path.basename(arcname))
        # repack
        value[i] = (fsname, arcname)
    return value


class Wheel:
    """A wheel representation that knows how to write itself out."""

    def __init__(self, distribution, version, build_tag=None, python_tag='py2.py3',
                 abi_tag='none', platform_tag='any'):
        """
        Parameters
        ----------
        distribution : str
            The 'distribution name', or the package name, e.g. "numpy"
        version : str
            The version string for the package
        build_tag : str or int, optional
            The build number, must start with a digit, See PEP #427
        python_tag : str, optional
            The Python version tag, see PEP #425
        abi_tag : str, optional
            The Python ABI tag, see PEP #425
        platform_tag : str, optional
            The platform tag, see PEP #425

        Attributes
        ----------
        noarch_python : bool
            Whether the package is a 'noarch: python' conda package.
        basedir : str or None,
            Location on filesystem where real files exist.
        scripts : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the scripts/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        includes : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the includes/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        files : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the path/to/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        """
        self.distribution = distribution
        self.version = version
        self.build_tag = build_tag
        self.python_tag = python_tag
        self.abi_tag = abi_tag
        self.platform_tag = platform_tag
        self.noarch_python = False
        self.basedir = None
        self.artifact_info = None
        self.entry_points = []
        self.moved_shared_libs = []
        self._records = [(f"{distribution}-{version}.dist-info/RECORD", "", "")]
        self._scripts = []
        self._includes = []
        self._files = []

    def __repr__(self):
        return f'{self.__class__.__name__}({self.filename})'

    def clean(self):
        if self.artifact_info is not None:
            self.artifact_info.clean()

    @property
    def filename(self):
        parts = [self.distribution.replace("-", "_"), self.version]
        if self.build_tag is not None and not self.noarch_python:
            parts.append(self.build_tag)
        parts.extend([self.python_tag, self.abi_tag, self.platform_tag])
        return '-'.join(parts) + '.whl'

    @property
    def compatibility_tag(self):
        return "-".join([self.python_tag, self.abi_tag, self.platform_tag])

    @property
    def scripts(self):
        return self._scripts

    @scripts.setter
    def scripts(self, value):
        arcdir = f"{self.distribution}-{self.version}.data/scripts"
        self._scripts = _normalize_path_mappings(value, self.basedir, arcdir)

    @scripts.deleter
    def scripts(self):
        self._scripts = None

    @property
    def includes(self):
        return self._includes

    @includes.setter
    def includes(self, value):
        arcdir = f"{self.distribution}-{self.version}.data/headers"
        self._includes = _normalize_path_mappings(value, self.basedir, arcdir)

    @includes.deleter
    def includes(self):
        self._includes = None

    @property
    def files(self):
        return self._files

    @files.setter
    def files(self, value):
        self._files = _normalize_path_mappings(value, self.basedir)

    @files.deleter
    def files(self):
        self._files = None

    def write(self):
        with ZipFile(self.filename, 'w', compression=ZIP_DEFLATED) as zf:
            self.zf = zf
            self.write_from_filesystem('scripts')
            self.write_from_filesystem('includes')
            self.write_from_filesystem('files')
            self.write_entry_points()
            self.write_top_level()
            self.write_metadata()
            self.write_license_file()
            self.write_wheel_metadata()
            self.write_record()  # This *has* to be the last write
            del self.zf

    def _writestr_and_record(self, arcname, data, zinfo=None):
        if isinstance(data, str):
            data = data.encode('utf-8')
        if zinfo is None:
            self.zf.writestr(arcname, data, compress_type=ZIP_DEFLATED)
        else:
            self.zf.writestr(zinfo, data, compress_type=ZIP_DEFLATED)
        record = (arcname, record_hash(data), len(data))
        self._records.append(record)

    def write_metadata(self):
        print('Writing metadata')
        lines = ["Metadata-Version: 2.1", "Name: " + self.distribution,
                 "Version: " + self.version]
        license = self.artifact_info.index_json.get("license", None)
        if license:
            lines.append("License: " + license)
        content = "\n".join(lines) + "\n"
        arcname = f"{self.distribution}-{self.version}.dist-info/METADATA"
        self._writestr_and_record(arcname, content)

    def write_license_file(self):
        license_file = os.path.join(self.basedir, 'info', 'LICENSE.txt')
        if not os.path.isfile(license_file):
            return
        print("Writing license file")
        with open(license_file, 'rb') as f:
            content = f.read()
        arcname = f"{self.distribution}-{self.version}.dist-info/LICENSE"
        self._writestr_and_record(arcname, content)

    def write_wheel_metadata(self):
        print('Writing wheel metadata')
        lines = ["Wheel-Version: 1.0", "Generator: conda-press " + VERSION]
        lines.append("Root-Is-Purelib: " + str(self.noarch_python).lower())
        lines.append("Tag: " + self.compatibility_tag)
        if self.build_tag is not None:
            lines.append("Build: " + self.build_tag)
        content = "\n".join(lines) + "\n"
        arcname = f"{self.distribution}-{self.version}.dist-info/WHEEL"
        self._writestr_and_record(arcname, content)

    def write_from_filesystem(self, name):
        print(f'Writing {name}')
        files = getattr(self, name)
        if not files:
            print('Nothing to write!')
            return
        for fsname, arcname in tqdm(files):
            absname = os.path.join(self.basedir, fsname)
            if not os.path.isfile(absname):
                continue
            elif False and os.path.islink(absname):
                # symbolic link, see https://gist.github.com/kgn/610907
                # unfortunately, pip doesn't extract symbolic links
                # properly. If this is fixed ever, replace "False and"
                # above. Until then, we have to make a copy in the archive.
                data = os.readlink(absname).encode('utf-8')
                zinfo = ZipInfo.from_file(absname, arcname=arcname)
                zinfo.external_attr = 0xA1ED0000
            else:
                with open(absname, 'br') as f:
                    data = f.read()
                zinfo = ZipInfo.from_file(absname, arcname=arcname)
            zinfo.compress_type = ZIP_DEFLATED
            self._writestr_and_record(arcname, data, zinfo=zinfo)

    def write_record(self):
        print('Writing record')
        lines = [f"{f},{h},{s}" for f, h, s in reversed(self._records)]
        content = "\n".join(lines)
        arcname = f"{self.distribution}-{self.version}.dist-info/RECORD"
        self.zf.writestr(arcname, content)

    def write_entry_points(self):
        if not self.entry_points:
            return
        print('Writing entry points')
        lines = ["[console_scripts]"]
        lines.extend(self.entry_points)
        content = "\n".join(lines)
        arcname = f"{self.distribution}-{self.version}.dist-info/entry_points.txt"
        self._writestr_and_record(arcname, content)

    def write_top_level(self):
        inits = []
        for fsname, arcname in self.files:
            if arcname.endswith('__init__.py'):
                pkg, _, _ = arcname.rpartition('/')
                inits.append(pkg)
        if not inits:
            return
        inits.sort(key=len)
        top_level = inits[0]
        print(f"Writing {top_level} to top_level.txt")
        arcname = f"{self.distribution}-{self.version}.dist-info/top_level.txt"
        self._writestr_and_record(arcname, top_level + "\n")

    #
    # rewrite the actual files going in to the Wheel, as needed
    #

    def rewrite_python_shebang(self):
        for fsname, arcname in self.scripts:
            fspath = os.path.join(self.basedir, fsname)
            with open(fspath, 'rb') as f:
                first = f.readline()
                if not first.startswith(b'#!'):
                    continue
                elif b'pythonw' in first:
                    shebang = b'#!pythonw\n'
                elif b'python' in first:
                    shebang = b'#!python\n'
                else:
                    continue
                remainder = f.read()
            print(f"rewriting shebang for {fsname}")
            replacement = shebang + remainder
            with open(fspath, 'wb') as f:
                f.write(replacement)

    def rewrite_rpaths(self):
        """Rewrite shared library relative (run) paths, as needed"""
        for fsname, arcname in self.moved_shared_libs:
            print(f'rewriting RPATH for {fsname}')
            fspath = os.path.join(self.basedir, fsname)
            containing_dir = os.path.dirname(arcname)
            relpath_to_lib = os.path.relpath("lib/", containing_dir)
            rpath_to_lib = "$ORIGIN/" + relpath_to_lib
            if sys.platform.startswith("linux"):
                current_rpath = $(patchelf --print-rpath @(fspath)).strip()
                new_rpath = rpath_to_lib + ":" + current_rpath if current_rpath else new_rpath
                print(f'  new RPATH is {new_rpath}')
                $(patchelf --set-rpath @(new_rpath) @(fspath))
            else:
                raise RuntimeError(f'cannot rewrite RPATHs on {sys.platform}')

    def rewrite_scripts_linking(self):
        """Write wrapper scripts so that dynamic linkings in the
        site-packages/lib/ directory will be picked up. These are
        platform specific.
        """
        subdir = self.artifact_info.subdir
        if subdir == "noarch":
            pass
        elif subdir.startswith("linux") or subdir.startswith("osx"):
            self.rewrite_scripts_linking_unix()
        elif subdir.startswith("win"):
            self.rewrite_scripts_linking_win()
        else:
            raise NotImplementedError("subdir not recognized")

    def write_unix_script_proxy(self, absname):
        root, ext = os.path.splitext(absname)
        proxyname = root + '-proxy' + ext
        basename = os.path.basename(absname)
        # choose the template to fill based on whether we have Python's major/minor
        # version numbers, or if we have to find the site-packages directory at
        # run time.
        with open(absname, 'rb') as f:
            shebang = f.readline(12).strip()
        is_py_script = (shebang == b"#!python")
        m = re_python_ver.match(self.artifact_info.python_tag)
        if m is None and is_py_script:
            pymajor = pyminor = None
            proxy_script = DYNAMIC_SP_PY_UNIX_PROXY_SCRIPT
        elif m is None and not is_py_script:
            pymajor = pyminor = None
            proxy_script = DYNAMIC_SP_UNIX_PROXY_SCRIPT
        elif m is not None and is_py_script:
            pymajor, pyminor = m.groups()
            proxy_script = KNOWN_SP_PY_UNIX_PROXY_SCRIPT
        else:
            pymajor, pyminor = m.groups()
            proxy_script = KNOWN_SP_UNIX_PROXY_SCRIPT
        src = proxy_script.format(basename=basename, pymajor=pymajor, pyminor=pyminor)
        with open(proxyname, 'w') as f:
            f.write(src)
        os.chmod(proxyname, 0o755)
        return proxyname

    def rewrite_scripts_linking_unix(self):
        # relocate the binaries inside the archive, write the proxy scripts
        new_scripts = []
        new_files = []
        for fsname, arcname in self.scripts:
            absname = os.path.join(self.basedir, fsname)
            basename = os.path.basename(absname)
            proxyname = self.write_unix_script_proxy(absname)
            new_files.append((fsname, 'bin/' + basename))
            new_scripts.append((proxyname, arcname))
        self.files.extend(new_files)
        self.scripts.clear()
        self.scripts.extend(new_scripts)

    def write_win_script_proxy(self, proxyname, basename, path_to_exe="Scripts"):
        # Windows does not need to choose the template to fill based on whether we have
        # Python's major/minor version numbers.
        proxy_script = WIN_PROXY_SCRIPT
        src = proxy_script.format(basename=basename, path_to_exe=path_to_exe)
        with open(proxyname, 'w', newline="\r\n") as f:
            f.write(src)
        return proxyname

    def rewrite_scripts_linking_win(self):
        # relocate the binaries inside the archive, write the proxy scripts
        new_scripts_map = {}
        new_files = []
        for fsname, arcname in self.scripts:
            absname = os.path.join(self.basedir, fsname)
            basename = os.path.basename(absname)
            root, ext = os.path.splitext(absname)
            proxyname = root + '-proxy.bat'
            new_files.append((fsname, 'Scripts/' + basename))
            arcroot, _ = os.path.splitext(arcname)
            if proxyname not in new_scripts_map or WIN_EXE_WEIGHTS[ext] > WIN_EXE_WEIGHTS[new_scripts_map[proxyname][2]]:
                new_scripts_map[proxyname] = (arcroot + ".bat", basename, ext, "Scripts")
        # add proxies to executables in non-standard places
        arcdir = f"{self.distribution}-{self.version}.data/scripts"
        for fsname in self.artifact_info.files:
            if fsname.startswith("Scripts/"):
                # in standard location
                continue
            absname = os.path.join(self.basedir, fsname)
            basename = os.path.basename(absname)
            root, ext = os.path.splitext(absname)
            if ext not in WIN_EXE_WEIGHTS:
                # not an executable
                continue
            proxyname = root + '-proxy.bat'
            arcname = arcdir + "/" + os.path.basename(root) + ".bat"
            if proxyname not in new_scripts_map or WIN_EXE_WEIGHTS[ext] > WIN_EXE_WEIGHTS[new_scripts_map[proxyname][2]]:
                path_to_exe = os.path.dirname(fsname).replace("/", "\\\\")
                new_scripts_map[proxyname] = (arcname, basename, ext, path_to_exe)
        # write proxy files
        new_scripts = []
        for proxyname, (arcname, basename, _, path_to_exe) in new_scripts_map.items():
            proxyname = self.write_win_script_proxy(proxyname, basename, path_to_exe)
            new_scripts.append((proxyname, arcname))
        # fix the script files themselves
        for fsname, _ in new_files:
            absname = os.path.join(self.basedir, fsname)
            root, ext = os.path.splitext(fsname)
            if ext == ".bat":
                print("munging path in " + fsname)
                with open(absname, 'r') as f:
                    fsfile = f.read()
                fsfile = fsfile.replace(r'@SET "PYTHON_EXE=%~dp0\..\python.exe"',
                                        r'@SET "PYTHON_EXE=%~dp0\..\..\..\Scripts\python.exe"')
                with open(absname, 'w') as f:
                    f.write(fsfile)
        # lock in the real values
        self.files.extend(new_files)
        self.scripts.clear()
        self.scripts.extend(new_scripts)
