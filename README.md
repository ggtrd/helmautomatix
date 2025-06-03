# Helmautomatix

Easily update all Helm Charts over differents Kubernetes namespaces.

Requirements:
- [kubectl](https://kubernetes.io/fr/docs/reference/kubectl/)
- [helm](https://helm.sh/docs/intro/install/)
- [jq](https://jqlang.org/)
- [yq](https://mikefarah.gitbook.io/yq)


Helmautomatix is POSIX compliant.


## Usage

### Using as a simple script
```
./helmautomatix.sh --help
```
### Installing on the current user
```
dir="/home/$USER/.helmautomatix" \
&& file="$dir/helmautomatix.sh" \
&& mkdir -p $dir \
&& curl https://raw.githubusercontent.com/ggtrd/helmautomatix/refs/heads/main/helmautomatix.sh -o $file \
&& chmod +x $file \
&& echo "alias helmautomatix='$file'" >> /home/$USER/.bashrc
```

### Main commands
List all arguments
```
./helmautomatix.sh --help
```
List local Charts in JSON format (get version, if updatable and their repository)
```
./helmautomatix.sh -l
```
Update listed Charts from -l argument
```
./helmautomatix.sh -u
```

# License
This project is licensed under the MIT License. See the [LICENSE](https://github.com/ggtrd/helmautomatix/blob/main/LICENSE.md) file