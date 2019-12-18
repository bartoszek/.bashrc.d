#!/bin/bash

#remove duplicate packages.

mapfile -t remote_repos < <(pacconf --repo-list|xargs -I{} sh -c "pacconf --repo={} Server|grep -vq ^file && echo {}")
mapfile -t local_repos < <(pacconf --repo-list|xargs -I{} sh -c "pacconf --repo={} Server|grep -q ^file && echo {}")
mapfile -t local_repos_path < <(IFS=$'\n'; xargs -I{} sh -c "pacconf --repo={} Server|grep -oP 'file://\K.*'" <<<"${local_repos[*]}")
cachedir=$(pacconf CacheDir|grep -vFf <(IFS=$'\n'; echo "${local_repos_path[*]}"))
mapfile -t remote_pkgs < <(pacman -Sql "${remote_repos[@]}")
mapfile -t local_pkgs < <(pacman -Sql "${local_repos[@]}")
mapfile -t duplicated_pkgs < <(comm -12 <(IFS=$'\n'; sort <<<"${local_pkgs[*]}") <(IFS=$'\n'; sort <<<"${remote_pkgs[*]}"))
mapfile -t pkgs_to_remove < <(
#shellcheck disable=SC2030
for pkg in "${duplicated_pkgs[@]}"; do
	#shellcheck disable=SC2183,SC2046
	printf "%15s\t%15s\t%15s\t%15s\t%30s\n" $(expac -S "%r %v" "$pkg") "$pkg"|tee /dev/stderr
done|vipe|rev|cut -f1|rev|tr -d ' ')
[[ -v pkgs_to_remove[@] ]] && {
	for i in $(seq 0 "$((${#local_repos[@]}-1))"); do
		echo repo-remove -R "${local_repos_path[$i]}"/"${local_repos[$i]}".db.tar.xz "${pkgs_to_remove[@]}"
		repo-remove -R "${local_repos_path[$i]}"/"${local_repos[$i]}".db.tar.xz "${pkgs_to_remove[@]}"
	done
}

mapfile -t pkgs_not_referenced_in_db < <(
for i in $(seq 0 "$((${#local_repos[@]}-1))"); do
	#comm -13 <(pacman -Slq "${local_repos[$i]}"|xargs -I{} pacman -Spdd "${local_repos[$i]}"/{}|grep -oP 'file://\K.*'|sort) <(ls "${local_repos_path[$i]}"/*pkg.tar.*)
	comm -13 <(pacman -Slq "${local_repos[$i]}"|xargs pacman -Spdd|grep -oP 'file://\K.*'|sort) <(ls "${local_repos_path[$i]}"/*pkg.tar.*)
done)

mapfile -t pkgs_missing_from_db < <(
for i in $(seq 0 "$((${#local_repos[@]}-1))"); do
	comm -23 <(pacman -Slq "${local_repos[$i]}"|xargs pacman -Spdd|grep -oP 'file://\K.*'|sort) <(ls "${local_repos_path[$i]}"/*pkg.tar.*)
done)

[[ -v pkgs_not_referenced_in_db[@] ]] && (
	IFS=$'\n'
	echo -e "pkgs not referenced in local db:\n${pkgs_not_referenced_in_db[*]}" >&2
	read -r -p "move unreferenced files to pacman cache? [yes|no]" ans
	[[ "$ans" == "yes" ]] && sudo mv -t "$cachedir" "${pkgs_not_referenced_in_db[@]}"
)
[[ -v pkgs_missing_from_db[@] ]] && (
	IFS=$'\n'
	echo -e "pkgs missing form local db:\n${pkgs_missing_from_db[*]}" >&2
)
exit 0

#create copy of remote repo
for repo in "${remote_repos[@]}"; do
	pacman -Slq "$repo"|xargs -I{} sudo pacman --noconfirm --config pacman.conf -Swdd "$repo"/{}
done
