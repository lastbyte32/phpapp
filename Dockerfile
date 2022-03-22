ARG PHP_VERSION="8.1"
ARG NGINX_VERSION="1.20.1"
ARG APP_BASE_DIR="."

FROM --platform=linux/amd64 php:${PHP_VERSION}-fpm-alpine AS base

# Required Args ( inherited from start of file, or passed at build )

# Maintainer label
LABEL maintainer="sherifabdlnaby@gmail.com"

# Set SHELL flags for RUN commands to allow -e and pipefail
# Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# ------------------------------------- Install Packages Needed Inside Base Image --------------------------------------

RUN IMAGE_DEPS="tini gettext openssl"; \
    RUNTIME_DEPS="fcgi"; \
    apk add --no-cache ${IMAGE_DEPS} ${RUNTIME_DEPS}

# ---------------------------------------- Install / Enable PHP Extensions ---------------------------------------------


RUN apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS  \
      libzip-dev    \
      icu-dev       \
      unixodbc-dev \
 # PHP Extensions --------------------------------- \
 && docker-php-ext-install -j$(nproc) \
      intl        \
      opcache     \
      pdo_mysql   \
      zip         \
 # Pecl Extensions -------------------------------- \
 && pecl install apcu && docker-php-ext-enable apcu \
 && pecl install sqlsrv && docker-php-ext-enable sqlsrv\
 && pecl install pdo_sqlsrv && docker-php-ext-enable pdo_sqlsrv  \
 # Cleanup ---------------------------------------- \
 && rm -r /tmp/pear; \
 # - Detect Runtime Dependencies of the installed extensions. \
 # - src: https://github.com/docker-library/wordpress/blob/master/latest/php8.0/fpm-alpine/Dockerfile \
    out="$(php -r 'exit(0);')"; \
		[ -z "$out" ]; \
		err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
		[ -z "$err" ]; \
		\
		extDir="$(php -r 'echo ini_get("extension_dir");')"; \
		[ -d "$extDir" ]; \
		runDeps="$( \
			scanelf --needed --nobanner --format '%n#p' --recursive "$extDir" \
				| tr ',' '\n' \
				| sort -u \
				| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
		)"; \
		# Save Runtime Deps in a virtual deps
		apk add --no-network --virtual .php-extensions-rundeps $runDeps; \
		# Uninstall Everything we Installed (minus the runtime Deps)
		apk del --no-network .build-deps; \
		# check for output like "PHP Warning:  PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
		err="$(php --version 3>&1 1>&2 2>&3)"; 	[ -z "$err" ]
      
# -----------------------------------------------

# mssql odbc for dabase connection
RUN curl -O https://download.microsoft.com/download/e/4/e/e4e67866-dffd-428c-aac7-8d28ddafb39b/msodbcsql17_17.9.1.1-1_amd64.apk && apk add --allow-untrusted msodbcsql17_17.9.1.1-1_amd64.apk


# - Clean bundled config/users & recreate them with UID 1000 for docker compatability in dev container.
# - Create composer directories (since we run as non-root later)
RUN deluser --remove-home www-data && adduser -u1000 -D www-data && rm -rf /var/www /usr/local/etc/php-fpm.d/* && \
    mkdir -p /var/www/.composer /app && chown -R www-data:www-data /app /var/www/.composer

# ------------------------------------------------ PHP Configuration ---------------------------------------------------

# Add Default Config
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Add in Base PHP Config
COPY docker/php/base-*   $PHP_INI_DIR/conf.d

# ---------------------------------------------- PHP FPM Configuration -------------------------------------------------

# PHP-FPM config
COPY docker/fpm/*.conf  /usr/local/etc/php-fpm.d/


COPY docker/*-base          \
     docker/healthcheck-*   \
     docker/command-loop    \
     # to
     /usr/local/bin/

RUN  chmod +x /usr/local/bin/*-base /usr/local/bin/healthcheck-* /usr/local/bin/command-loop

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer


WORKDIR /app
USER www-data

# Common PHP Frameworks Env Variables
ENV APP_ENV prod
ENV APP_DEBUG 0

# Validate FPM config (must use the non-root user)
RUN php-fpm -t

HEALTHCHECK CMD ["healthcheck-liveness"]
ENTRYPOINT ["entrypoint-base"]
CMD ["php-fpm"]

# ==============================================  PRODUCTION IMAGE  ====================================================

FROM base AS app


ARG PHP_VERSION
ARG APP_BASE_DIR

WORKDIR /app


ARG APP_BASE_DIR
USER root

# Copy Prod Scripts
COPY docker/*-prod /usr/local/bin/
RUN  chmod +x /usr/local/bin/*-prod

# Copy PHP Production Configuration
COPY docker/php/prod-*   $PHP_INI_DIR/conf.d/

USER www-data

# ----------------------------------------------- Production Config -----------------------------------------------------

# Copy App Code
COPY --chown=www-data:www-data $APP_BASE_DIR/ .


RUN post-build-base && post-build-prod

ENTRYPOINT ["entrypoint-prod"]
CMD ["php-fpm"]

# ==============================================  DEVELOPMENT IMAGE  ===================================================

FROM base as app-dev


ENV APP_ENV dev
ENV APP_DEBUG 1

# Switch root to install stuff
USER root

# For Composer Installs
RUN apk --no-cache add git openssh;
# ---------------------------------------------------- Scripts ---------------------------------------------------------

# Copy Dev Scripts
COPY docker/*-dev /usr/local/bin/
RUN chmod +x /usr/local/bin/*-dev; \
# ------------------------------------------------------ PHP -----------------------------------------------------------
    mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini" 

COPY docker/php/dev-*   $PHP_INI_DIR/conf.d/

USER www-data

# Entrypoints
ENTRYPOINT ["entrypoint-dev"]
CMD ["php-fpm"]



#                                                  --- NGINX ---
FROM nginx:${NGINX_VERSION}-alpine AS nginx

RUN rm -rf /var/www/* /etc/nginx/conf.d/* && adduser -u 1000 -D -S -G www-data www-data
COPY docker/nginx/nginx-*   /usr/local/bin/
COPY docker/nginx/          /etc/nginx/
RUN chown -R www-data /etc/nginx/ && chmod +x /usr/local/bin/nginx-*

# The PHP-FPM Host
## Localhost is the sensible default assuming image run on a k8S Pod
ENV PHP_FPM_HOST "localhost"
ENV PHP_FPM_PORT "9000"
ENV NGINX_LOG_FORMAT "json"

# For Documentation
EXPOSE 8080

# Switch User
USER www-data

# Add Healthcheck
HEALTHCHECK CMD ["nginx-healthcheck"]

# Add Entrypoint
ENTRYPOINT ["nginx-entrypoint"]

# ======================================================================================================================
#                                                 --- NGINX PROD ---
# ======================================================================================================================

FROM nginx AS web

# Copy Public folder + Assets that's going to be served from Nginx
COPY --chown=www-data:www-data --from=app /app/public /app/public

# ======================================================================================================================
#                                                 --- NGINX DEV ---
# ======================================================================================================================
FROM nginx AS web-dev

ENV NGINX_LOG_FORMAT "combined"

COPY --chown=www-data:www-data docker/nginx/dev/*.conf   /etc/nginx/conf.d/
COPY --chown=www-data:www-data docker/nginx/dev/certs/   /etc/nginx/certs/