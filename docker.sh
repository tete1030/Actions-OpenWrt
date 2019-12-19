#!/usr/bin/env bash

if [ "x$NO_FAILEXIT" != "x1" ]; then
  set -eo pipefail
fi

# helper functions
_exit_if_empty() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "Missing input $var_name" >&2
    exit 1
  fi
}

_get_full_image_name() {
  echo ${REGISTRY:+$REGISTRY/}${IMAGE_NAME}
}

# action steps
check_required_input() {
  _exit_if_empty USERNAME "${USERNAME}"
  _exit_if_empty PASSWORD "${PASSWORD}"
  _exit_if_empty IMAGE_NAME "${IMAGE_NAME}"
  _exit_if_empty IMAGE_TAG "${IMAGE_TAG}"
  _exit_if_empty CONTEXT "${CONTEXT}"
  _exit_if_empty DOCKERFILE "${DOCKERFILE}"
}

configure_docker() {
  echo '{
    "max-concurrent-downloads": 50,
    "max-concurrent-uploads": 50
  }' | sudo tee /etc/docker/daemon.json
  sudo service docker restart
  docker buildx rm builder || true
  docker buildx create --use --name builder --node builder0 --driver docker-container ${EXTRA_BUILDX_CREATE_OPTS}
}

login_to_registry() {
  echo "${PASSWORD}" | docker login -u "${USERNAME}" --password-stdin "${REGISTRY}"
}

pull_image() {
  # docker pull --all-tags "$(_get_full_image_name)" 2> /dev/null || true
  echo "Nothing to pull when using BuildKit"
}

build_image() {
  IFS_ORI="$IFS"
  IFS=$'\x20'
  declare -a cache_from
  declare -a cache_to

  if [ "x$NO_REMOTE_CACHE" = "x1" ]; then
    if [ "x$INLINE_CACHE" = "x1" ]; then
      cache_from+=( "--cache-from=type=registry,ref=$(_get_full_image_name):${IMAGE_TAG}-build" )
      cache_to+=( "--cache-to=type=inline,mode=min" )
    else
      if [ -f "./cache/index.json" ]; then
        cache_from+=( "--cache-from=type=local,src=./cache" )
      fi
      cache_to+=( "--cache-to=type=local,dest=./cache" )
      if [ ! -d "./cache" ]; then
        mkdir ./cache
      fi
    fi

    if [ ! -z "${IMAGE_BASE}" ]; then
      cache_from+=( "--cache-from=type=registry,ref=${IMAGE_BASE}" )
    else
      cache_from+=( "--cache-from=type=registry,ref=$(_get_full_image_name):${IMAGE_TAG}" )
    fi

  else
    cache_from+=( "--cache-from=type=registry,ref=$(_get_full_image_name):buildcache" )
    cache_to+=( "--cache-to=type=registry,ref=$(_get_full_image_name):buildcache,mode=max" )
  fi
  echo "From cache: ${cache_from[@]}"
  echo "To cache: ${cache_to[@]}"

  declare -a build_target
  if [ ! -z "${1}" ]; then
    build_target+=( "--target=${1}" )
  fi
  declare -a build_args
  if [ ! -z "${BUILD_ARGS}" ]; then
    for arg in ${BUILD_ARGS[@]};
    do
      if [ -z "${!arg}" ]; then
        echo "Warning: variable \`${arg}\` is empty" >&2
      fi
      build_args+=( --build-arg "${arg}=${!arg}" )
    done
  fi

  declare -a build_other_opts
  if [ "x$NO_PUSH" = "x1" ]; then
    build_other_opts+=( --output=type=image,push=false )
  else
    build_other_opts+=( --push )
  fi
  build_other_opts+=( "--tag=$(_get_full_image_name):${IMAGE_TAG}-build" )

  # build image using cache
  docker buildx build \
    "${build_target[@]}" \
    "${build_args[@]}" \
    "${cache_from[@]}" \
    "${cache_to[@]}" \
    "${build_other_opts[@]}" \
    ${EXTRA_BUILDX_BUILD_OPTS} \
    --progress=plain \
    "--file=${CONTEXT}/${DOCKERFILE}" \
    "${CONTEXT}"

  IFS="$IFS_ORI"
}

copy_files() {
  COPY_CACHE_DIR="cache/buildresult"
  BUILDRESULT_IMAGE_DIR="/buildresult"
  TAG="$(_get_full_image_name):${IMAGE_TAG}-build"
  if [ -d "${COPY_CACHE_DIR}" -a ! -z "$(eval ls -A \"${COPY_CACHE_DIR}\" 2>/dev/null)" ]; then
    echo "Error: \'${COPY_CACHE_DIR}\' directory already exists and not empty" >&2
    exit
  fi
  mkdir -p "${COPY_CACHE_DIR}" || true
  docker buildx build --no-cache --target buildresult "--output=type=local,dest=${COPY_CACHE_DIR}" - << EOF
FROM scratch AS buildresult
WORKDIR "${BUILDRESULT_IMAGE_DIR}"
COPY --from="${TAG}" "${1}" ./
EOF
  all_files=( "${COPY_CACHE_DIR}/${BUILDRESULT_IMAGE_DIR}"/* )
  mv "${all_files[@]}" "${2}"
  all_other_files=( "${COPY_CACHE_DIR}"/* )
  rm -rf "${all_other_files[@]}" || true
  # docker run -d -i --rm --name builder "$(_get_full_image_name):${IMAGE_TAG}"
  # docker exec builder stat "$1"
  # docker cp builder:"$1" "$2"
}

push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  local image_with_git_tag
  image_with_git_tag="$(_get_full_image_name):gittag-$git_tag"
  # docker tag "$(_get_full_image_name):${IMAGE_TAG}" "$image_with_git_tag"
  # docker push "$image_with_git_tag"
  docker buildx imagetools create -t "$image_with_git_tag" "$(_get_full_image_name):${IMAGE_TAG}"
}

push_image() {
  # push image
  # docker push "$(_get_full_image_name):${IMAGE_TAG}"
  docker buildx imagetools create -t "$(_get_full_image_name):${IMAGE_TAG}" "$(_get_full_image_name):${IMAGE_TAG}-build"
  push_git_tag
}

logout_from_registry() {
  docker logout "${REGISTRY}"
}

check_required_input
