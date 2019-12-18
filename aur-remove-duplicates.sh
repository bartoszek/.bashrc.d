#!/bin/bash

#remove duplicate packages.

mapfile -t remote_repos < <(pacconf --repo-list|xargs -I{} sh -c "pacconf --repo={} Server|grep -vq ^file && echo {}")
mapfile -t local_repos < <(pacconf --repo-list|xargs -I{} sh -c "pacconf --repo={} Server|grep -q ^file && echo {}")
mapfile -t local_repos_path < <(IFS=$'\n'; xargs -I{} sh -c "pacconf --repo={} Server|grep -oP 'file://\K.*'" <<<"${local_repos[*]}")
mapfile -t remote_pkgs < <(pacman -Sql "${remote_repos[@]}")
mapfile -t local_pkgs < <(pacman -Sql "${local_repos[@]}")
mapfile -t duplicated_pkgs < <(comm -12 <(IFS=$'\n'; sort <<<"${local_pkgs[*]}") <(IFS=$'\n'; sort <<<"${remote_pkgs[*]}"))
mapfile -t pkgs_to_remove < <(
#shellcheck disable=SC2030
for pkg in "${duplicated_pkgs[@]}"; do
	#shellcheck disable=SC2183,SC2046
	printf "%15s\t%15s\t%15s\t%15s\t%30s\n" $(expac -S "%r %v" "$pkg") "$pkg"|tee /dev/stderr
done|vipe|rev|cut -f1|rev|tr -d ' ')
[[ -v pkgs_to_remove[@] ]] || exit 0;
for i in $(seq 0 "$((${#local_repos[@]}-1))"); do
	echo repo-remove -R "${local_repos_path[$i]}"/"${local_repos[$i]}".db.tar.xz "${pkgs_to_remove[@]}"
	repo-remove -R "${local_repos_path[$i]}"/"${local_repos[$i]}".db.tar.xz "${pkgs_to_remove[@]}"
done

exit 0

#create copy of remote repo
for repo in "${remote_repos[@]}"; do
	pacman -Slq "$repo"|xargs -I{} sudo pacman --noconfirm --config pacman.conf -Swdd "$repo"/{}
done
