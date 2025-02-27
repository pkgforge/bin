#!/usr/bin/env bash
## <DO NOT RUN STANDALONE, meant for CI Only>
## Meant to Sync All Packages to https://huggingface.co/datasets/pkgforge/pkgcache
## Self: https://raw.githubusercontent.com/pkgforge/bin/refs/heads/main/sync.sh
# bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge/bin/refs/heads/main/sync.sh") "${REPO}"
#-------------------------------------------------------#

#-------------------------------------------------------#
##ENV
export TZ="UTC"
SYSTMP="$(dirname $(mktemp -u))" && export SYSTMP="${SYSTMP}"
TMPDIR="$(mktemp -d)" && export TMPDIR="${TMPDIR}" ; echo -e "\n[+] Using TEMP: ${TMPDIR}\n"
if [[ -z "${USER_AGENT+x}" ]]; then
 USER_AGENT="$(curl -qfsSL 'https://raw.githubusercontent.com/pkgforge/devscripts/refs/heads/main/Misc/User-Agents/ua_firefox_macos_latest.txt')"
fi
##Host
HOST_TRIPLET="$(uname -m)-$(uname -s)"
export HOST_TRIPLET="$(echo "${HOST_TRIPLET}" | tr -d '[:space:]')"
export HOST_TRIPLET_L="${HOST_TRIPLET,,}"
##Sanity
 if [[ -z "${GIT_USER+x}" ]]; then
   echo -e "[-] FATAL: User '\${GIT_USER}' is NOT Set\n"
  exit 1
 fi
 if [[ -z "${GITHUB_TOKEN+x}" ]]; then
   echo -e "[-] FATAL: Token '\${GITHUB_TOKEN}' is NOT Set\n"
  exit 1
 fi
#repo
 if [[ -z "${UPSTREAM_REPO+x}" ]]; then
   echo -e "[-] FATAL: Repository '\${UPSTREAM_REPO}' is NOT Set\n"
  exit 1
 else
   pushd "$(mktemp -d)" &>/dev/null &&\
    git clone --filter="blob:none" --depth="1" --no-checkout "https://${GIT_USER}:${GITHUB_TOKEN}@github.com/pkgforge/bin" && cd "./bin" &&\
    unset REPO_DIR ; REPO_DIR="$(realpath .)" && export REPO_DIR="${REPO_DIR}"
     if [ ! -d "${REPO_DIR}" ] || [ $(du -s "${REPO_DIR}" | cut -f1) -le 100 ]; then
       echo -e "\n[X] FATAL: Failed to clone GH Repo\n"
      exit 1
     else
       PKG_DIR="${REPO_DIR}/${HOST_TRIPLET}" && export PKG_DIR="${PKG_DIR}"
       mkdir -pv "${PKG_DIR}" ; git fetch origin main
       git sparse-checkout set ""
       git sparse-checkout set --no-cone --sparse-index "/README.md"
       git checkout
       ls -lah "." "${PKG_DIR}" ; git sparse-checkout list
     fi
   popd &>/dev/null
 fi
#Oras
if ! command -v oras &> /dev/null; then
  echo -e "[-] Failed to find oras\n"
 exit 1
else
  oras login --username "Azathothas" --password "${GHCR_TOKEN}" "ghcr.io"
fi
##Metadata
curl -qfsSL "https://meta.pkgforge.dev/${UPSTREAM_REPO}/${HOST_TRIPLET}.json" -o "${TMPDIR}/METADATA.json"
if [[ "$(cat "${TMPDIR}/METADATA.json" | jq -r '.[] | .ghcr_blob' | wc -l)" -le 20 ]]; then
  echo -e "\n[-] FATAL: Failed to Fetch ${UPSTREAM_REPO} (${HOST_TRIPLET}) Metadata\n"
 exit 1
fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
sync_to_gh()
{
 ##Chdir
  pushd "${REPO_DIR}" &>/dev/null
 ##Enable Debug
  if [ "${DEBUG}" = "1" ] || [ "${DEBUG}" = "ON" ]; then
     set -x
  fi
 ##Input
  unset GHCR_BLOB GH_INPUT GH_PKGID GH_PKGNAME
  local INPUT="${1:-$(cat)}"
  export GH_INPUT="$(echo "${INPUT}" | tr -d '[:space:]')"
  if [ -z "${GH_INPUT+x}" ] || [ -z "${GH_INPUT##*[[:space:]]}" ]; then
     echo -e "[-] FATAL: Failed to get Package ID <== (${INPUT})"
   return 1
  else
     echo -e "\n[+] Processing: ${GH_INPUT}"
     export GH_PKGID="$(echo "${GH_INPUT}" | awk -F'[:#]' '{print $2}' | tr -d '[:space:]')"
     export GH_PKGNAME="$(echo "${GH_INPUT}" | awk -F'[#]' '{print $1}' | tr -d '[:space:]')"
     if [ -z "${GH_PKGNAME+x}" ] || [ -z "${GH_PKGNAME##*[[:space:]]}" ]; then
       echo -e "[-] FATAL: Failed to get Package Name <== (${GH_PKGNAME})"
      return 1
     else
       echo -e "[+] PKG_ID: ${GH_PKGID}"
       echo -e "[+] PKG_NAME: ${GH_PKGNAME} [${GH_PKGID}]"
     fi
  fi
 ##Get needed vars
  GHCR_BLOB="$(cat "${TMPDIR}/METADATA.json" | jq -r '.[] | select((.pkg_id | ascii_downcase) == (env.GH_PKGID | ascii_downcase) and .pkg_name == env.GH_PKGNAME) | .ghcr_blob' | grep -im1 "${UPSTREAM_REPO}" | tr -d '[:space:]')"
  export GHCR_BLOB
  if [ -z "${GHCR_BLOB+x}" ] || [ -z "${GHCR_BLOB##*[[:space:]]}" ]; then
    echo -e "[-] FATAL: Failed to get GHCR Blob <== [${GH_PKGID}]"
   return 1
  else
    echo -e "[+] GHCR_BLOB: ${GHCR_BLOB} [${GH_PKGID}]"
  fi
 ##Download/Upload
   oras blob fetch "${GHCR_BLOB}" --output "${PKG_DIR}/${GH_PKGNAME}"
   if [[ -s "${PKG_DIR}/${GH_PKGNAME}" && $(stat -c%s "${PKG_DIR}/${GH_PKGNAME}") -gt 10 ]]; then
     #Chmod
      chmod 'a+x' "${PKG_DIR}/${GH_PKGNAME}"
   else
     echo -e "[-] FATAL: Failed to Download GHCR Blob <== [${GH_INPUT}]"
   fi
 ##Disable Debug 
  if [ "${DEBUG}" = "1" ] || [ "${DEBUG}" = "ON" ]; then
     set +x
  fi
}
export -f sync_to_gh
#-------------------------------------------------------#

#-------------------------------------------------------#
##Run
pushd "${REPO_DIR}" &>/dev/null
 unset GH_PKG_INPUT ; readarray -t "GH_PKG_INPUT" < <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge/bin/refs/heads/main/PKG_LIST.txt" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^#' | grep -i ":${UPSTREAM_REPO}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sort -u)
 if [[ -n "${GH_PKG_INPUT[*]}" && "${#GH_PKG_INPUT[@]}" -le 1 ]]; then
   echo -e "\n[+] Total Packages: ${#GH_PKG_INPUT[@]}\n"
  exit 0
 else
   echo -e "\n[+] Total Packages: ${#GH_PKG_INPUT[@]}\n"
   printf '%s\n' "${GH_PKG_INPUT[@]}" | xargs -P "${PARALLEL_LIMIT:-$(($(nproc)+1))}" -I "{}" bash -c 'sync_to_gh "$@"' _ "{}"
   if [[ -d "${PKG_DIR}" ]] && [[ "$(du -s "${PKG_DIR}" | cut -f1 | tr -d '[:space:]')" -gt 100 ]]; then
     pushd "${REPO_DIR}" &>/dev/null &&\
       find "${REPO_DIR}" -type f ! -path "./.git/*" -size -3c -delete
       find "${REPO_DIR}" -path "${REPO_DIR}/.git" -prune -o -type f -size +95M -exec rm -rvf "{}" + 2>/dev/null
       find "${PKG_DIR}" -type f ! -path "./.git/*" -exec dos2unix --quiet "{}" \; 2>/dev/null
       git sparse-checkout add "${HOST_TRIPLET}/**"
       git sparse-checkout list
       COMMIT_MSG="[+] Sync [${HOST_TRIPLET})"
       find "${PKG_DIR}" -maxdepth 1 -type f -not -path "*/\.*" | xargs -I "{}" git add "{}" --verbose
       git add --all --renormalize --verbose
       git commit -m "${COMMIT_MSG}"
     pushd "${REPO_DIR}" &>/dev/null
       retry_git_push()
        {
         for i in {1..5}; do
          #Generic Merge
           git pull origin main --ff-only || git pull --rebase origin main
           git merge --no-ff -m "${COMMIT_MSG}"
          #Push
           git pull origin main 2>/dev/null
           if git push -u origin main; then
              echo -e "\n[+] Pushed ==> ${HOST_TRIPLET}\n"
              break
           fi
          #Sleep randomly 
           sleep "$(shuf -i 500-4500 -n 1)e-3"
         done
        }
        export -f retry_git_push
        retry_git_push
        git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
        if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
         echo -e "\n[-] WARN: Failed to push ==> ${HOST_TRIPLET}\n(Retrying ...)\n"
         retry_git_push
         git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
         if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
           echo -e "\n[-] FATAL: Failed to push ==> ${HOST_TRIPLET}\n"
           retry_git_push
         fi
        fi
   fi
  du -sh "${REPO_DIR}" && realpath "${REPO_DIR}" 
 fi
popd &>/dev/null
#-------------------------------------------------------#