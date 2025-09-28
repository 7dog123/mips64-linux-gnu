#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Configuration
# ----------------------------
_target=mips64-linux-gnu
_target_arch=mips
pkgdir="$PWD/pkg"      # Destination root
srcdir="$PWD/src"      # Source downloads

mkdir -p "$pkgdir" "$srcdir"

cp -Rv *.patch ${srcdir}
cp -Rv *.h ${srcdir}

ABIS=('64' 'n32' '32')
DEFAULT_ABI='64'

export PATH="$pkgdir/usr/bin:$PATH"

# ----------------------------
# Helper functions
# ----------------------------
stage_marker() {
    [[ -f "$pkgdir/.stage_$1.done" ]] && return 0 || return 1
}

mark_stage_done() {
    touch "$pkgdir/.stage_$1.done"
}

# ----------------------------
# 1. binutils
# ----------------------------
if ! stage_marker "binutils"; then
    echo "=== Building binutils ==="
    cd "$srcdir"
    wget -nc "https://ftpmirror.gnu.org/gnu/binutils/binutils-2.45.tar.xz"
    tar xf binutils-2.45.tar.xz
    mkdir -p build-binutils && cd build-binutils

    "$srcdir/binutils-2.45/configure" \
        --build="$(gcc -dumpmachine)" \
        --host="$(gcc -dumpmachine)" \
        --target="$_target" \
        --prefix='/usr' \
        --with-sysroot="/usr/${_target}" \
        --enable-cet \
        --enable-deterministic-archives \
        --enable-new-dtags \
        --enable-gold \
        --enable-ld='default' \
        --enable-lto \
        --enable-plugins \
        --enable-relro \
        --enable-threads \
        --enable-multilib \
        --disable-gdb \
        --disable-werror \
        --with-debuginfod \
        --with-pic \
        --with-system-zlib \
        --with-gnu-as \
        --with-gnu-ld

    make -j"$(nproc)"
   # make -k LDFLAGS='' check || true
    make DESTDIR="$pkgdir" install

    # remove unwanted Windows files
    rm "$pkgdir/usr/share/man/man1/${_target}"-{dlltool,windmc,windres}* || true
    rm -r "$pkgdir/usr"/{lib/bfd-plugins,share/{info,locale}} || true

    # replace cross-directory hardlinks with symlinks
    rm -f "$pkgdir/usr/${_target}/bin"/*
    while read -r -d '' file; do
        ln -s "../../bin/${file##*/}" "$pkgdir/usr/${_target}/bin/${file##*"${_target}-"}"
    done < <(find "$pkgdir/usr/bin" -type f -print0)

    mark_stage_done "binutils"
fi

# ----------------------------
# 2. Linux API headers
# ----------------------------
if ! stage_marker "linux-api-headers"; then
    echo "=== Installing Linux API headers ==="
    cd "$srcdir"
    wget -nc "https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.16.tar.xz"
    tar xf linux-6.16.tar.xz

    make -C "linux-6.16" ARCH="$_target_arch" mrproper
    make -C "linux-6.16" INSTALL_HDR_PATH="$pkgdir/usr/${_target}" ARCH="$_target_arch" headers_install

    mark_stage_done "linux-api-headers"
fi

# ----------------------------
# 3. GCC Bootstrap
# ----------------------------
if ! stage_marker "gcc-bootstrap"; then
    echo "=== Building GCC bootstrap ==="
    cd "$srcdir"
    wget -nc "https://sourceware.org/pub/gcc/releases/gcc-15.1.0/gcc-15.1.0.tar.xz"
    tar xf gcc-15.1.0.tar.xz
    patch -d "gcc-15.1.0" -Np1 -i "$srcdir/010-gcc-Wno-format-security.patch"

    mkdir -p build-gcc-bootstrap && cd build-gcc-bootstrap

    # Clean CFLAGS
	CFLAGS="${CFLAGS:-}"; CXXFLAGS="${CXXFLAGS:-}"
    for opt in '-pipe' '-Werror=format-security' '-fstack-clash-protection' '-fcf-protection'; do
        export CFLAGS="${CFLAGS//$opt/}"
        export CXXFLAGS="${CXXFLAGS//$opt/}"
    done

    "$srcdir/gcc-15.1.0/configure" \
        --build="$(gcc -dumpmachine)" \
        --host="$(gcc -dumpmachine)" \
        --target="$_target" \
        --prefix='/usr' \
        --libdir='/usr/lib' \
        --libexecdir='/usr/lib' \
        --mandir='/usr/share/man' \
        --with-sysroot="/usr/${_target}" \
        --with-build-sysroot="/usr/${_target}" \
        --with-native-system-header-dir='/include' \
        --with-abi="$DEFAULT_ABI" \
        --with-newlib \
        --with-gnu-as \
        --with-gnu-ld \
        --enable-languages='c,c++' \
        --with-isl \
        --with-linker-hash-style='gnu' \
        --with-system-zlib \
        --enable-__cxa_atexit \
        --enable-cet='auto' \
        --enable-checking='release' \
        --enable-clocale='newlib' \
        --disable-default-pie \
        --enable-default-ssp \
        --enable-gnu-indirect-function \
        --enable-gnu-unique-object \
        --enable-install-libiberty \
        --enable-linker-build-id \
        --enable-lto \
        --enable-multilib \
        --enable-plugin \
        --disable-shared \
        --disable-threads \
        --disable-libssp \
        --disable-libstdcxx-pch \
        --disable-libunwind-exceptions \
        --disable-werror

    make all-gcc all-target-libgcc
    make DESTDIR="$pkgdir" install-gcc install-target-libgcc

    # allow using gnuabi${ABI} executables
    for _abi in "${ABIS[@]}"; do
        for _bin in c++ cpp g++ gcc "gcc-15.1.0"; do
            if [[ "$_abi" == "$DEFAULT_ABI" ]]; then
                ln -s "${_target}-${_bin}" "$pkgdir/usr/bin/${_target/gnu/"gnuabi${_abi}"}-${_bin}"
            else
                cat <<- __EOF__ | install -D -m755 /dev/stdin "$pkgdir/usr/bin/${_target/gnu/"gnuabi${_abi}"}-${_bin}"
				#!/bin/sh
				exec ${_target}-${_bin} -mabi='${_abi}' "\$@"
__EOF__
            fi
            case "$_bin" in cpp|g++|gcc) 
                ln -s "${_target}-${_bin}.1.gz" "$pkgdir/usr/share/man/man1/${_target/gnu/"gnuabi${_abi}"}-${_bin}.1.gz"
            esac
        done
    done

    # remove conflicting files
    rm -rf "$pkgdir/usr/share"/{info,locale,man/man7}

    # strip target binaries
    find "$pkgdir/usr/lib/gcc/${_target}" -type f \( -name '*.a' -o -name '*.o' \) -exec "${_target}-objcopy" -R .comment -R .note -R .debug_info -R .debug_aranges -R .debug_pubnames -R .debug_pubtypes -R .debug_abbrev -R .debug_line -R .debug_str -R .debug_ranges -R .debug_loc '{}' \;
    find "$pkgdir/usr/bin" "$pkgdir/usr/lib/gcc/${_target}" -type f -executable -exec strip '{}' \;

    mark_stage_done "gcc-bootstrap"
fi

# ----------------------------
# 4. glibc
# ----------------------------
if ! stage_marker "glibc"; then
	pkgname="${_target}-glibc"
	pkgver=2.42
	
    echo "=== Building glibc ==="
    cd "$srcdir"
	wget -nc "https://ftpmirror.gnu.org/gnu/glibc/glibc-2.42.tar.xz"
    tar xf glibc-2.42.tar.xz

	for _abi in "${ABIS[@]}"; do
		mkdir -p "build-abi-${_abi}"
		printf '%s\n' "slibdir=/lib/glibc/abi-${_abi}" > "build-abi-${_abi}/configparms"
		printf '%s\n' "rtlddir=/lib/glibc/abi-${_abi}" >> "build-abi-${_abi}/configparms"
		printf '%s\n' 'rootsbindir=/bin' >> "build-abi-${_abi}/configparms"
		printf '%s\n' 'sbindir=/bin' >> "build-abi-${_abi}/configparms"
	done
	
	install -d -m755 sys
	cp -Rv "$srcdir/sdt.h" sys/sdt.h
	cp -Rv "$srcdir/sdt-config.h" sys/sdt-config.h

    _configure_flags=(
        --build="$(gcc -dumpmachine)"
        --host="${_target}"
        --target="${_target}"
        --prefix="/usr"
        --includedir="/include"
        --with-headers="$pkgdir/usr/${_target}/include"
        --enable-add-ons
        --enable-bind-now
        --disable-cet
        --enable-fortify-source
        --enable-kernel=4.4
        --enable-lock-elision
        --disable-multi-arch
        --enable-stack-protector=strong
        --enable-stackguard-randomization
        --disable-static-pie
        --enable-systemtap
        --disable-nscd
        --disable-profile
        --disable-werror
    )

    # Fix CFLAGS
    CFLAGS="${CFLAGS:-}"; CXXFLAGS="${CXXFLAGS:-}"
    # remove fortify for building libraries
    export CFLAGS="${CFLAGS/-Wp,-D_FORTIFY_SOURCE=?/}"
    export CXXFLAGS="${CXXFLAGS/-Wp,-D_FORTIFY_SOURCE=?/}"
    
    # build fixes
    export CFLAGS="$(sed -E 's/-fno-plt//;s/-fcf-protection//;s/-mno-omit-leaf-frame-pointer//' <<< "$CFLAGS")"
    export CXXFLAGS="$(sed -E 's/-fno-plt//;s/-fcf-protection//;s/-mno-omit-leaf-frame-pointer//' <<< "$CXXFLAGS")"
    export CFLAGS="$(sed -E 's/\-m(arch|tune|cpu|fpu|abi)(=|[[:space:]]*|)[[:alnum:]-]*//g' <<< "$CFLAGS")"
    export CXXFLAGS="$(sed -E 's/\-m(arch|tune|cpu|fpu|abi)(=|[[:space:]]*|)[[:alnum:]-]*//g' <<< "$CXXFLAGS")"

    export BUILD_CC='gcc'
    export AR="${_target}-ar"
    export RANLIB="${_target}-ranlib"

    for _abi in "${ABIS[@]}"
    do
        cd "${srcdir}/build-abi-${_abi}"
        export CC="${_target}-gcc -mabi=${_abi} -I${srcdir}"
        export CXX="${_target}-g++ -mabi=${_abi} -I${srcdir}"
        
        "${srcdir}/glibc-${pkgver}/configure" \
            --libdir="/lib/${pkgname##*-}/abi-${_abi}" \
            --libexecdir="/lib/${pkgname##*-}/abi-${_abi}" \
            "${_configure_flags[@]}"
        
        printf '%s\n' 'build-programs=no' >> configparms
        make
	done

    # strip static/shared libraries
    for _abi in "${ABIS[@]}"
    do
        make install_root="${pkgdir}/usr/${_target}" install
        
        find "${pkgdir}/usr/${_target}/lib/${pkgname##*-}/abi-${_abi}" -name '*.a' -type f \
            -exec "${_target}-strip" --strip-debug {} + 2> /dev/null || true
        
        # do not strip these for gdb and valgrind functionality, but strip the rest
        find "${pkgdir}/usr/${_target}/lib/${pkgname##*-}/abi-${_abi}" \
            -not -name 'ld-*.so' \
            -not -name 'libc-*.so' \
            -not -name 'libpthread-*.so' \
            -not -name 'libthread_db-*.so' \
            -name '*-*.so' -type f -exec "${_target}-strip" --strip-unneeded {} + 2> /dev/null || true
    done
    
    # provide tracing probes to libstdc++ for exceptions, possibly for other
    # libraries too. Useful for gdb's catch command.
    install -D -m644 sdt{,-config}.h -t "${pkgdir}/usr/${_target}/include/sys"
    
    # remove unneeded files
    rm -r "${pkgdir}/usr/${_target}"/{etc,usr/share,var} || true

    mark_stage_done "glibc"
fi

# ----------------------------
# 5. Final GCC
# ----------------------------
if ! stage_marker "gcc-final"; then
    echo "=== Building final GCC ==="
    cd "$srcdir"
    mkdir -p build-gcc-final && cd build-gcc-final
    patch -d "$srcdir/gcc-15.1.0" -Np1 -i "$srcdir/020-gcc-config-mips-multilib.patch" || true

    "$srcdir/gcc-15.1.0/configure" \
        --build="$(gcc -dumpmachine)" \
        --host="$(gcc -dumpmachine)" \
        --target="$_target" \
        --prefix='/usr' \
        --libdir='/usr/lib' \
        --libexecdir='/usr/lib' \
        --mandir='/usr/share/man' \
        --with-sysroot="/usr/${_target}" \
        --with-build-sysroot="/usr/${_target}" \
        --with-native-system-header-dir='/include' \
        --with-abi="$DEFAULT_ABI" \
        --with-gnu-as \
        --with-gnu-ld \
        --enable-languages='c,c++' \
        --with-isl \
        --with-linker-hash-style='gnu' \
        --with-system-zlib \
        --enable-__cxa_atexit \
        --enable-cet='auto' \
        --enable-checking='release' \
        --enable-clocale='gnu' \
        --disable-default-pie \
        --enable-default-ssp \
        --enable-gnu-indirect-function \
        --enable-gnu-unique-object \
        --enable-install-libiberty \
        --enable-linker-build-id \
        --enable-lto \
        --enable-multilib \
        --enable-plugin \
        --enable-shared \
        --enable-threads='posix' \
        --disable-libssp \
        --disable-libstdcxx-pch \
        --disable-libunwind-exceptions \
        --disable-werror \
        --disable-libsanitizer

    make -j"$(nproc)"
    make DESTDIR="$pkgdir" install-gcc install-target-{libgcc,libstdc++-v3,libgomp,libgfortran,libquadmath}

    # allow using gnuabi${ABI} executables
    for _abi in "${ABIS[@]}"; do
        for _bin in c++ cpp g++ gcc "gcc-15.1.0"; do
            if [[ "$_abi" == "$DEFAULT_ABI" ]]; then
                ln -s "${_target}-${_bin}" "$pkgdir/usr/bin/${_target/gnu/"gnuabi${_abi}"}-${_bin}"
            else
                cat <<- __EOF__ | install -D -m755 /dev/stdin "$pkgdir/usr/bin/${_target/gnu/"gnuabi${_abi}"}-${_bin}"
				#!/bin/sh
				exec ${_target}-${_bin} -mabi='${_abi}' "\$@"
__EOF__
            fi
            case "$_bin" in cpp|g++|gcc) 
                ln -s "${_target}-${_bin}.1.gz" "$pkgdir/usr/share/man/man1/${_target/gnu/"gnuabi${_abi}"}-${_bin}.1.gz"
            esac
        done
    done

    # remove conflicting files
    rm -rf "$pkgdir/usr/share"/{"gcc-15.1.0",info,locale,man/man7}

    # strip target binaries
    find "$pkgdir/usr/lib/gcc/${_target}" "$pkgdir/usr/${_target}/lib" -type f \( -name '*.a' -o -name '*.o' \) -exec "${_target}-objcopy" -R .comment -R .note -R .debug_info -R .debug_aranges -R .debug_pubnames -R .debug_pubtypes -R .debug_abbrev -R .debug_line -R .debug_str -R .debug_ranges -R .debug_loc '{}' \;
    find "$pkgdir/usr/bin" "$pkgdir/usr/lib/gcc/${_target}" -type f -executable -exec strip '{}' \;

    mark_stage_done "gcc-final"
fi

echo "=== Cross-toolchain build complete! ==="
