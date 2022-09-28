FROM nginx:mainline-alpine as builder

ENV ENABLED_MODULES="headers-more ndk perl set-misc"

RUN set -ex \
    && apk update \
    && apk add linux-headers openssl-dev pcre2-dev zlib-dev openssl abuild \
               musl-dev libxslt libxml2-utils make mercurial gcc unzip git \
               xz g++ coreutils \
    # allow abuild as a root user \
    && printf "#!/bin/sh\\nSETFATTR=true /usr/bin/abuild -F \"\$@\"\\n" > /usr/local/bin/abuild \
    && chmod +x /usr/local/bin/abuild \
    && hg clone -r ${NGINX_VERSION}-${PKG_RELEASE} https://hg.nginx.org/pkg-oss/ \
    && cd pkg-oss \
    && mkdir /tmp/packages \
    && for module in $ENABLED_MODULES; do \
        echo "Building $module for nginx-$NGINX_VERSION"; \
        if [ -d /modules/$module ]; then \
            echo "Building $module from user-supplied sources"; \
            # check if module sources file is there and not empty
            if [ ! -s /modules/$module/source ]; then \
                echo "No source file for $module in modules/$module/source, exiting"; \
                exit 1; \
            fi; \
            # some modules require build dependencies
            if [ -f /modules/$module/build-deps ]; then \
                echo "Installing $module build dependencies"; \
                apk update && apk add $(cat /modules/$module/build-deps | xargs); \
            fi; \
            # if a module has a build dependency that is not in a distro, provide a
            # shell script to fetch/build/install those
            # note that shared libraries produced as a result of this script will
            # not be copied from the builder image to the main one so build static
            if [ -x /modules/$module/prebuild ]; then \
                echo "Running prebuild script for $module"; \
                /modules/$module/prebuild; \
            fi; \
            /pkg-oss/build_module.sh -v $NGINX_VERSION -f -y -o /tmp/packages -n $module $(cat /modules/$module/source); \
            BUILT_MODULES="$BUILT_MODULES $(echo $module | tr '[A-Z]' '[a-z]' | tr -d '[/_\-\.\t ]')"; \
        elif make -C /pkg-oss/alpine list | grep -E "^$module\s+\d+" > /dev/null; then \
            echo "Building $module from pkg-oss sources"; \
            cd /pkg-oss/alpine; \
            make abuild-module-$module BASE_VERSION=$NGINX_VERSION NGINX_VERSION=$NGINX_VERSION; \
            apk add $(. ./abuild-module-$module/APKBUILD; echo $makedepends;); \
            make module-$module BASE_VERSION=$NGINX_VERSION NGINX_VERSION=$NGINX_VERSION; \
            find ~/packages -type f -name "*.apk" -exec mv -v {} /tmp/packages/ \;; \
            BUILT_MODULES="$BUILT_MODULES $module"; \
        else \
            echo "Don't know how to build $module module, exiting"; \
            exit 1; \
        fi; \
    done \
    && echo "BUILT_MODULES=\"$BUILT_MODULES\"" > /tmp/packages/modules.env

FROM nginx:mainline-alpine
COPY --from=builder /tmp/packages /tmp/packages

ENV DOLLAR="$" \
    HTTP_EXPECT_CT="enforce, max-age=30" \
    HTTP_FEATURE_POLICY="accelerometer 'none'; ambient-light-sensor 'none'; autoplay 'none'; camera 'none'; fullscreen 'self'; geolocation 'none'; gyroscope 'none'; magnetometer 'none'; microphone 'none'; midi 'none'; payment 'none'; speaker 'none'; sync-xhr 'self'; usb 'none'; vr 'none';" \
    HTTP_PERMISSIONS_POLICY="accelerometer=(); ambient-light-sensor=(); autoplay=(); camera=(); fullscreen=(self); geolocation=(); gyroscope=(); interest-cohort=(); magnetometer=(); microphone=(); midi=(); payment=(); speaker=(); sync-xhr=(self); usb=(); vr=();" \
    HTTP_REFERRER_POLICY="strict-origin-when-cross-origin" \
    HTTP_STRICT_TRANSPORT_SECURITY="max-age=31536000; includeSubDomains; preload" \
    HTTP_X_CONTENT_TYPE_OPTIONS="nosniff" \
    HTTP_X_DOWNLOAD_OPTIONS="noopen" \
    HTTP_X_FRAME_OPTIONS="SAMEORIGIN" \
    HTTP_X_PERMITTED_CROSS_DOMAIN_POLICIES="none" \
    HTTP_X_XSS_PROTECTION="1; mode=block"

COPY default.conf.template /etc/nginx/templates/

RUN set -ex \
    && . /tmp/packages/modules.env \
    && for module in $BUILT_MODULES; do \
           apk add --no-cache --allow-untrusted /tmp/packages/nginx-module-${module}-${NGINX_VERSION}*.apk; \
       done \
    && rm -rf /tmp/packages

COPY entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 3000
CMD ["nginx", "-g", "daemon off; load_module modules/ndk_http_module.so; load_module modules/ngx_http_headers_more_filter_module.so; load_module modules/ngx_http_perl_module.so; load_module modules/ngx_http_set_misc_module.so;"]
