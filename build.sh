#!/bin/bash

set -x
cd $(pwd)
cp rpm/geoclue-provider-gpsd3.spec ~/rpmbuild/SPECS
pushd ..
tar czf ~/rpmbuild/SOURCES/geoclue-provider-gpsd3.tar.gz geoclue-provider-gpsd3
popd
rpmbuild -bb rpm/geoclue-provider-gpsd3.spec
