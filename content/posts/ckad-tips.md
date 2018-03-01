---
title: "A few tips to prepare for your CKAD exam"
date: 2019-07-15
draft: false
cover: /images/card-default-cover.png
tags:
- ckad
- kubernetes
- infrastructure
categories:
- infrastructure
---

I just finished CKAD exam a few days ago with a score of 90% (passing score is 66%). It was really a fun and at the same time challenging exam so I thought I should note down a few tips that really helped me prepare for this exam. A few of these tips are already covered in some other blog posts, a few are mine.

# Type fast

The exam is really intense and you will need to compete with time in order to finish all 19 questions in 2 hours. The faster you type, the more time you have to think through the problem. So practice your typing skill if you feel your typing speed is not fast enough.

# Know your text editor well

The exam is entirely in command line so you will need to use a few editors available in Linux environment like vim or nano. And again, since time is really a scarce resouce, make sure you are able to use the editor of choice comfortably. I'm using vim in my daily work so it's not much of a problem for me. Below are a few things that I setup at the beginning of the exam to be more productive:

``` shell
" in .vimrc
autocmd FileType yml,yaml setlocal ts=2 sts=2 sw=2 expandtab

inoremap jk <Esc>
cnoremap ke kubectl explain
```

The `autocmd` sets the tab setting for yaml files to be 2 spaces. Without this line, you will find yourself struggling a lot with formatting and indentation of yaml in vim

I also map `jk` to `Esc` in insert mode. I use this mapping in my day-to-day vim operation too. You don't need to follow my mapping but it's important to have one mapping for `Esc` because `Esc` button is not working as expected in the exam. During the exam, pressing `Esc` actually loses the focus of the emulator pane instead of exiting insert mode. Alternatively, you can use `Ctrl + C` in MacOS to quit insert mode but it feels unnatural for me.

The last line map `ke` to `kubectl explain` in command mode. You will find yourself typing a lot of `kubectl explain` in vim so this saves quite a lot of typing.

Additionally, I also map `kubectl` to `k` in bash shell:

``` shell
alias k=kubectl
alias ka='kubectl apply -f'
```

# Get used to kubectl explain

Although you are allowed to open one more browser tab to check Kubernetes docs website, I find typing `kubectl explain` directly from text editors/terminal much faster. There were only 2 times when I found myself switching to Kubernetes docs site: when I wanted to find sample YAML files for `PersistentVolume/PersistentVolumeClaim` and `Service`.

# Use `--dry-run` or `--export` to generate YAML files

- Generating YAML files using `--dry-run`:

``` shell
kubectl run some-deployment-name --image=some-image --dry-run -o yaml > deployment.yml
kubectl run some-pod-name --restart=Never --image=some-image --dry-run -o yaml > pod.yml
kubectl run some-job-name --restart=OnFailure --image=some-image --dry-run -o yaml > job.yml
kubectl run some-cron-name --schedule="*/1 * * * *" --restart=OnFailure --image=some-image --dry-run -o yaml > cron.yml
```

- Exporting existing resources in cluster before editing:

``` shell
kubectl get deployment some-deployment --export -o yaml > deploy.yml
vim deploy.yml
kubectl apply -f deploy.yml
```

# Always create yaml files before creating resources in Kubernetes

During the exam, before creating any resource, I created corresponding yaml files (using `--dry-run` or `--export` flags) and prefixed those files with question number (.e.g. 4.pod.yml, 6.svc.yml). This helps me quickly get back to the question if I decide to skip that question and returned to it later. There was one instance when I finished question 4, went on with other questions and realized later that the pod in that question 4 was failing after a while. With this approach, I can quickly open `4.pod.yml` to continue working on that question.

# Resources

- The classic book [Kubernetes in Action](https://www.amazon.com/Kubernetes-Action-Marko-Luksa/dp/1617293725)
- [LinuxAcademy CKAD course](https://linuxacademy.com/containers/training/course/name/certified-kubernetes-application-developer-ckad/): this course covers all the necessary concepts for the exam. The labs are especially good and can get you familiar with format of exam questions.

And of course all the tips above will be useless if you don't know how to solve the problems. So make sure you know the exam syllabus well and have a lot of practice writing YAML files manually.
