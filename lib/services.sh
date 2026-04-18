#!/usr/bin/env bash
# services.sh — build (code + image), push, release

_svc_build_tool() { ctrl_service_field "$1" '.build.tool // "maven"'; }
_svc_build_dir()  { ctrl_service_field "$1" '.build.dir // ""'; }
_svc_build_args() { ctrl_service_field "$1" '.build.args // ""'; }
_svc_image()      { ctrl_service_field "$1" '.image // ""'; }
_svc_tag()        { ctrl_service_field "$1" '.tag // "latest"'; }
_svc_dockerfile() { ctrl_service_field "$1" '.build.dockerfile // "Dockerfile"'; }
_svc_context()    { ctrl_service_field "$1" '.build.context // ""'; }
_svc_platform()   { ctrl_service_field "$1" '.build.platform // "linux/amd64"'; }

_svc_image_ref() {
  local svc="$1"
  local image; image="$(_svc_image "${svc}")"
  local tag; tag="$(_svc_tag "${svc}")"
  [[ -n "${image}" ]] || fail "Service '${svc}' has no image defined in ctrl.yaml"
  printf '%s:%s' "${image}" "${tag}"
}

_svc_abs_dir() {
  local svc="$1"
  local dir; dir="$(_svc_build_dir "${svc}")"
  [[ -n "${dir}" ]] || fail "Service '${svc}' has no build.dir defined"
  # resolve relative to ctrl.yaml location
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  if [[ "${dir}" == /* ]]; then printf '%s' "${dir}"; else printf '%s/%s' "${base}" "${dir}"; fi
}

# ── sc-core / prerequisite builds ────────────────────────────────────────────
_SC_CORE_BUILT=0

_build_prerequisites() {
  local svc="$1"
  local prereqs; prereqs="$(echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | .build.prerequisites[]? // \"\"" 2>/dev/null || true)"
  [[ -z "${prereqs}" || "${prereqs}" == "null" ]] && return 0
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local p
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "null" ]] && continue
    local abs_p="${base}/${p}"
    if [[ -f "${abs_p}/mvnw" ]]; then
      msg "Building prerequisite: ${p}"
      run_op "mvnw install ${p}" bash -c "cd '${abs_p}' && ./mvnw -Dmaven.test.skip=true clean install"
    elif [[ -f "${abs_p}/pom.xml" ]]; then
      msg "Building prerequisite: ${p}"
      run_op "mvn install ${p}" bash -c "cd '${abs_p}' && mvn -Dmaven.test.skip=true clean install"
    fi
  done <<< "${prereqs}"
}

# ── build code ────────────────────────────────────────────────────────────────
build_code_service() {
  local svc="$1"
  local tool; tool="$(_svc_build_tool "${svc}")"
  local dir; dir="$(_svc_abs_dir "${svc}")"
  local extra; extra="$(_svc_build_args "${svc}")"
  [[ -d "${dir}" ]] || fail "Build directory not found for '${svc}': ${dir}"

  _build_prerequisites "${svc}"

  case "${tool}" in
    maven)
      local wrapper="${dir}/mvnw"
      if [[ -f "${wrapper}" ]]; then
        run_op "build ${svc}" bash -c "cd '${dir}' && ./mvnw -Dmaven.test.skip=true clean package ${extra}"
      else
        run_op "build ${svc}" bash -c "cd '${dir}' && mvn -Dmaven.test.skip=true clean package ${extra}"
      fi
      ;;
    gradle)
      run_op "build ${svc}" bash -c "cd '${dir}' && ./gradlew build -x test ${extra}"
      ;;
    npm)
      run_op "build ${svc}" bash -c "cd '${dir}' && npm ci && npm run build ${extra}"
      ;;
    make)
      run_op "build ${svc}" bash -c "cd '${dir}' && make ${extra}"
      ;;
    shell)
      local script; script="$(ctrl_service_field "${svc}" '.build.script // ""')"
      [[ -n "${script}" ]] || fail "build.tool=shell requires build.script for service '${svc}'"
      run_op "build ${svc}" bash -c "cd '${dir}' && bash '${script}' ${extra}"
      ;;
    skip|none)
      msg_verbose "Skipping code build for ${svc} (tool=skip)"
      ;;
    *)
      fail "Unknown build.tool '${tool}' for service '${svc}'"
      ;;
  esac
  msg_ok "Built code: ${svc}"
}

# ── build image ───────────────────────────────────────────────────────────────
DOCKER_LOGGED_IN=0

_docker_login_once() {
  [[ "${DOCKER_LOGGED_IN}" -eq 0 ]] || return 0
  require_cmd docker
  local username="${DOCKERHUB_USERNAME:-}"
  local password="${DOCKERHUB_PASSWORD:-}"
  [[ -n "${username}" ]] || fail "DOCKERHUB_USERNAME is not set"
  [[ -n "${password}" ]] || fail "DOCKERHUB_PASSWORD is not set"
  msg "Logging into registry as ${username}"
  run_op "docker login" bash -c "printf '%s' '${password}' | docker login --username '${username}' --password-stdin"
  DOCKER_LOGGED_IN=1
}

build_image_service() {
  local svc="$1"
  local image_ref; image_ref="$(_svc_image_ref "${svc}")"
  local platform; platform="$(_svc_platform "${svc}")"

  local repo_dir; repo_dir="$(_svc_abs_dir "${svc}")"
  local dockerfile; dockerfile="$(_svc_dockerfile "${svc}")"
  local context; context="$(_svc_context "${svc}")"
  [[ -z "${context}" || "${context}" == "null" ]] && context="${repo_dir}"

  local df_path="${repo_dir}/${dockerfile}"
  [[ -f "${df_path}" ]] || fail "Dockerfile not found: ${df_path}"

  msg "Building image ${image_ref}"
  run_op "docker build ${svc}" docker buildx build \
    --platform "${platform}" \
    -f "${df_path}" \
    -t "${image_ref}" \
    "${context}"
  msg_ok "Built image: ${image_ref}"
}

push_image_service() {
  local svc="$1"
  local image_ref; image_ref="$(_svc_image_ref "${svc}")"
  _docker_login_once
  msg "Pushing ${image_ref}"
  run_op "docker push ${svc}" docker push "${image_ref}"
  msg_ok "Pushed: ${image_ref}"
}

release_service() {
  local svc="$1"
  build_code_service "${svc}"
  build_image_service "${svc}"
  push_image_service "${svc}"
}
