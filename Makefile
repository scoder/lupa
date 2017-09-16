PYTHON?=python
USE_BUNDLE?=true
VERSION?=$(shell sed -ne "s|^VERSION\s*=\s*'\([^']*\)'.*|\1|p" setup.py)

MANYLINUX_IMAGE_X86_64=quay.io/pypa/manylinux1_x86_64
MANYLINUX_IMAGE_686=quay.io/pypa/manylinux1_i686

.PHONY: all local test clean realclean

all:  local

local:
	${PYTHON} setup.py build_ext --inplace

test: local
	PYTHONPATH=. $(PYTHON) -m lupa.tests.test

clean:
	rm -fr build lupa/_lupa.so

realclean: clean
	rm -fr lupa/_lupa.c

wheel_manylinux: wheel_manylinux64 wheel_manylinux32

wheel_manylinux32 wheel_manylinux64: dist/lupa-$(VERSION).tar.gz
	echo "Building wheels for Lupa $(VERSION)"
	mkdir -p wheelhouse_$(subst wheel_,,$@)
	time docker run --rm -t \
		-v $(shell pwd):/io \
		-e CFLAGS="-O3 -g0 -mtune=generic -pipe -fPIC" \
		-e LDFLAGS="$(LDFLAGS) -fPIC" \
		-e LUPA_USE_BUNDLE=$(USE_BUNDLE) \
		-e WHEELHOUSE=wheelhouse_$(subst wheel_,,$@) \
		$(if $(patsubst %32,,$@),$(MANYLINUX_IMAGE_X86_64),$(MANYLINUX_IMAGE_686)) \
		bash -c 'for PYBIN in /opt/python/*/bin; do \
		    $$PYBIN/python -V; \
		    { $$PYBIN/pip wheel -w /io/$$WHEELHOUSE /io/$< & } ; \
		    done; wait; \
		    for whl in /io/$$WHEELHOUSE/lupa-$(VERSION)-*-linux_*.whl; do auditwheel repair $$whl -w /io/$$WHEELHOUSE; done'
