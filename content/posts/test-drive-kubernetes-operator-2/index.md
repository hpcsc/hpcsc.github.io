---
title:  "Test drive a Kubernetes operator - Part 2"
description:  "Create a simple Kubernetes operator following TDD"
date: 2021-07-25
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- golang
- kubernetes
- unit-testing
categories:
- programming
---

In the previous [post]({{< relref "/posts/test-drive-kubernetes-operator-1/index.md" >}}), we scaffolded the skeleton of our operator and also added functionality to create github repository when the custom resource `GithubRepository` is created.

In this post, we are going to build on top of that and add functionalities to update and delete the created github repository.

# Posts in the series

- [Scaffold and first slice of the operator: creation of github repository]({{< relref "/posts/test-drive-kubernetes-operator-1/index.md" >}})
- Update and delete of github repository (this post)
- [Creating of github repository by cloning another repository]({{< relref "/posts/test-drive-kubernetes-operator-3/index.md" >}})
- [Validation using webhooks]({{< relref "/posts/test-drive-kubernetes-operator-4/index.md" >}})

# Update function

## End to end test

We again start with a failing end to end test:

```go
Context("When GithubRepository resource updated", func() {
	var name, namespace string
	var githubRepository pnguyeniov1.GithubRepository

	BeforeEach(func() {
		namespace = "default"
		name = fmt.Sprintf("existing-repo-%d", rand.IntnRange(1000, 9000))
	})

	It("should update github repository using github API", func() {
		githubRepository = pnguyeniov1.GithubRepository{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: namespace,
			},
			Spec: pnguyeniov1.GithubRepositorySpec{
				Owner:       "test-owner",
				Repo:        name,
				Description: "initial description",
			},
		}

		err := k8sClient.Create(context.TODO(), &githubRepository)
		Expect(err).NotTo(HaveOccurred())

		Eventually(func() {
			var resource pnguyeniov1.GithubRepository
			err := k8sClient.Get(context.TODO(), types.NamespacedName{
				Namespace: namespace,
				Name:      name,
			}, &resource)
			Expect(err).NotTo(HaveOccurred())
			Expect(resource.Status.Successful).To(BeTrue())
		}, 10*time.Second, time.Second).Should(Succeed())

		githubRepository.Spec.Description = "updated description"
		k8sClient.Update(context.TODO(), &githubRepository)

		history, err := smocker.RequestByPath(fmt.Sprintf("/repos/test-owner/%s", name), "PATCH", "name", name)
		Expect(err).NotTo(HaveOccurred())

		Expect(history.Response.Status).To(Equal(200))
		Expect(history.Response.Body.(map[string]interface{})["name"]).To(Equal(name))
	})

	AfterEach(func() {
		err := k8sClient.Delete(context.TODO(), &githubRepository)
		if err != nil {
			logf.Log.Error(err, "failed to delete GithubRepository", "name", name)
		}
	})
})
```

A few things to notice:

- The test uses the name `existing-repo-{random-id}` for custom resource and git repo name. This is intended because smocker was setup to return 200 response for any GET request with repo name `existing-repo` in the path. We are telling smocker to tell github client that that repo exists in github
- For now we only support updating repo description. Owner and repo name cannot be updated and we will add validation for that in subsequent post.
- In previous end to end test, we have a helper functiion `waitUntilSuccessful()` to keep checking until controller sets status of the custom resource to successful. Turn out Ginkgo comes with Omega matcher library that has `Eventually` that does exactly the same thing. We can replace our custom code with this:

```go
Eventually(func() {
	var resource pnguyeniov1.GithubRepository
	err := k8sClient.Get(context.TODO(), types.NamespacedName{
		Namespace: namespace,
		Name:      name,
	}, &resource)
	Expect(err).NotTo(HaveOccurred())
	Expect(resource.Status.Successful).To(BeTrue())
}, 10*time.Second, time.Second).Should(Succeed())
```

Run the test and we should see an error on no smocker request in history matching our expectation.

## Refactor githubapi package

In the previous post, we decided `githubapi.CreateRepository()` does a checking of whether given repository exists in github before creating it. Now we need to consider how to implement the same check for update function.

We have several options:

- Move logic of checking whether a repo exists in github to another function in `githubapi`, say `githubapi.RepositoryExists()`. Controller will use that to decide to call `githubapi.CreateRepository()` or `githubapi.UpdateRepository()`. Controller will use the same way to check before doing deletion later too.
- Or update the existing function `githubapi.CreateRepository()` to do the checking and decide whether to create or update. The function name will need to be updated to `githubapi.CreateOrUpdateRepository()`. Later when implementing delete function, we will need to repeat the same check in that function too.

I choose option 2 simply because I don't want to put too much logic in controller.

I will skip over the renaming of `githubapi.CreateRepository()` to `githubapi.CreateOrUpdateRepository()`. It can be done easily with IDE.

We have a test in previous post to check that `githubapi.CreateRepository()` not doing a POST to github if repository exists. Let's update that test to check for github PATCH (repo update) call:

```go
t.Run("call github api to update when repository exists", func(t *testing.T) {
	baseUrl := "http://localhost:8088"
	uploadUrl := "http://localhost:8088"
	token := "valid-token"
	repoName := fmt.Sprintf("existing-repo-%d", rand.IntnRange(1000, 9000))
	api := New(context.TODO(), baseUrl, uploadUrl, token)

	err := api.CreateOrUpdateRepository("test-owner", repoName, "some-description")

	require.NoError(t, err)
	history, err := smocker.RequestByPath(fmt.Sprintf("/repos/test-owner/%s", repoName), "PATCH", "name", repoName)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, history.Response.Status)
	require.Equal(t, repoName, history.Response.Body.(map[string]interface{})["name"])
})
```

to pass the test, we need to add a smocker definition that responds to github PATCH request:

```yaml
- request:
    path:
      matcher: ShouldMatch
      value: /api/v3/repos/.*/existing-repo.*
    method: PATCH
  dynamic_response:
    engine: go_template
    script: |-
      status: 200
      headers:
        Content-Type: [application/json]
      body: >
        {
          "id": 1296269,
          "name": "{{ regexReplaceAll "/api/v3/repos/.*/(existing-repo.*)" .Request.Path "${1}" }}",
          "full_name": "{{.Request.Path | replace "/api/v3/repos/" "" }}"
        }
```

and modify `githubapi.CreateOrUpdateRepository()` to call github update:

```go
// ...
if resp.StatusCode == http.StatusNotFound {
	_, _, err = client.Repositories.Create(a.ctx, "", &repository)
	if err != nil {
		return fmt.Errorf("failed to create repository %s: error: %v", repo, err)
	}
} else {
	_, _, err = client.Repositories.Edit(a.ctx, owner, repo, &repository)
	if err != nil {
		return fmt.Errorf("failed to update repository %s: error: %v", repo, err)
	}
}
// ...
```

That also passes the end to end test

# Delete function

## End to end test

A similar end to end test:

```go
Context("When GithubRepository resource deleted", func() {
	var name, namespace string
	var githubRepository pnguyeniov1.GithubRepository

	BeforeEach(func() {
		namespace = "default"
		name = fmt.Sprintf("existing-repo-%d", rand.IntnRange(1000, 9000))
	})

	It("should delete github repository using github API", func() {
		githubRepository = pnguyeniov1.GithubRepository{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: namespace,
			},
			Spec: pnguyeniov1.GithubRepositorySpec{
				Owner:       "test-owner",
				Repo:        name,
				Description: "initial description",
			},
		}

		err := k8sClient.Create(context.TODO(), &githubRepository)
		Expect(err).NotTo(HaveOccurred())

		Eventually(func() {
			var resource pnguyeniov1.GithubRepository
			err := k8sClient.Get(context.TODO(), types.NamespacedName{
				Namespace: namespace,
				Name:      name,
			}, &resource)
			Expect(err).NotTo(HaveOccurred())
			Expect(resource.Status.Successful).To(BeTrue())
		}, 10*time.Second, time.Second).Should(Succeed())

		err = k8sClient.Delete(context.TODO(), &githubRepository)
		Expect(err).NotTo(HaveOccurred())

		Eventually(func() {
			history, err := smocker.RequestByPath(fmt.Sprintf("/repos/test-owner/%s", name), "DELETE", "", "")
			Expect(err).NotTo(HaveOccurred())
			Expect(history.Response.Status).To(Equal(204))
		}, 10*time.Second, time.Second).Should(Succeed())
	})
})
```

This time we just delete the `GithubRepository` custom resouce and expect a DELETE request is recorded in smocker

## Implement deletion

Back to `githubapi` test, we need to add tests for a new function `DeleteRepository()`. Start with happy path test:

```go
t.Run("call github api to delete when repository exists", func(t *testing.T) {
	baseUrl := "http://localhost:8088"
	uploadUrl := "http://localhost:8088"
	token := "valid-token"
	repoName := fmt.Sprintf("existing-repo-%d", rand.IntnRange(1000, 9000))
	api := New(context.TODO(), baseUrl, uploadUrl, token)

	err := api.DeleteRepository("test-owner", repoName)

	require.NoError(t, err)
	history, err := smocker.RequestByPath(fmt.Sprintf("/repos/test-owner/%s", repoName), "DELETE", "name", repoName)
	require.NoError(t, err)
	require.Equal(t, http.StatusNoContent, history.Response.Status)
})
```

Add mock definition to respond to DELETE request and simplest code to pass the test:

```go
func (a *api) DeleteRepository(owner, repo string) error {
	ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: a.token})
	oauthClient := oauth2.NewClient(a.ctx, ts)
	client, err := github.NewEnterpriseClient(a.baseUrl, a.uploadUrl, oauthClient)
	if err != nil {
		return fmt.Errorf("failed to create github client: %v", err)
	}

	client.Repositories.Delete(a.ctx, owner, repo)
	return nil
}
```

Now add test to make sure it returns error correctly when something's wrong:

```go
t.Run("return error when failed to delete repository", func(t *testing.T) {
	baseUrl := "http://localhost:8088"
	uploadUrl := "http://localhost:8088"
	token := ""
	repoName := fmt.Sprintf("existing-repo-%d", rand.IntnRange(1000, 9000))
	api := New(context.TODO(), baseUrl, uploadUrl, token)

	err := api.DeleteRepository("test-owner", repoName)

	require.Error(t, err)
	require.Contains(t, err.Error(), fmt.Sprintf("failed to delete repository %s", repoName))
})
```

Add smocker mock definition and update code to return error if any:

```go
// ...
_, err = client.Repositories.Delete(a.ctx, owner, repo)
if err != nil {
	return fmt.Errorf("failed to delete repository %s: error: %v", repo, err)
}

return nil
```

Last test is to make sure we don't call delete if repo not exists in github:

```go
t.Run("not call github api to delete when repository not exists", func(t *testing.T) {
	baseUrl := "http://localhost:8088"
	uploadUrl := "http://localhost:8088"
	token := "valid-token"
	repoName := fmt.Sprintf("delete-repo-%d", rand.IntnRange(1000, 9000))
	api := New(context.TODO(), baseUrl, uploadUrl, token)

	err := api.DeleteRepository("test-owner", repoName)

	require.NoError(t, err)
	_, err = smocker.RequestByPath(fmt.Sprintf("/repos/test-owner/%s", repoName), "DELETE", "", "")
	require.Error(t, err)
	require.Contains(t, err.Error(), "no smocker history matching")
})
```

Update code to check whether repo exists:

```go
// ...
_, resp, err := client.Repositories.Get(a.ctx, owner, repo)
if err != nil && resp.StatusCode != http.StatusNotFound {
	return fmt.Errorf("failed to get repository %s: error: %v", repo, err)
}

if resp.StatusCode == http.StatusNotFound {
	return nil
}
// ...
```

Before we move on, let's do some refactoring and clean up in `githubapi` package. Parameters like `baseUrl`, `uploadUrl` are only needed when creating github client, so we can move it to `New()` function:

```go
func New(ctx context.Context, baseUrl, uploadUrl, token string) (*api, error) {
	client, err := newGithubClient(ctx, baseUrl, uploadUrl, token)
	if err != nil {
		return nil, fmt.Errorf("failed to create github client: %v", err)
	}

	return &api{
		ctx:    ctx,
		client: client,
	}, nil
}
```

that's a breaking change since the function returns additional error now. Thankfully it's simple to fix

next change is to move all hardcoded smocker url `http://localhost:8088` in `api_test.go` to a const in the test. It can be updated to take the value from environment variable later.

We are done with `githubapi` package change. The remaining is to use it in the controller: when `GithubRepository` custom resource is deleted, controller should call `githubapi.DeleteRepository()` to delete given repository

## Add finalizer to controller

Kubernetes and operators use finalizer to implement deletion logic. Further details can be found in:

- [https://kubernetes.io/blog/2021/05/14/using-finalizers-to-control-deletion/](https://kubernetes.io/blog/2021/05/14/using-finalizers-to-control-deletion/)
- [https://book.kubebuilder.io/reference/using-finalizers.html](https://book.kubebuilder.io/reference/using-finalizers.html)

The kubebuilder book even gives us a template/pattern to follow, so it's straightforward in our case:

```go
// githubrepository_controller.go
// ...
if resource.ObjectMeta.DeletionTimestamp.IsZero() {
	if !controllerutil.ContainsFinalizer(&resource, FinalizerName) {
		// setup finalizer
		controllerutil.AddFinalizer(&resource, FinalizerName)
		if err := r.Update(ctx, &resource); err != nil {
			return ctrl.Result{}, fmt.Errorf("unable to add finalizer: %v", err)
		}
	}

	if err := api.CreateOrUpdateRepository(resource.Spec.Owner, resource.Spec.Repo, resource.Spec.Description); err != nil {
		return ctrl.Result{}, err
	}

	resource.Status.Successful = true
	if err := r.Status().Update(ctx, &resource); err != nil {
		return ctrl.Result{}, fmt.Errorf("unable to update status of GithubRepository resource: %v", err)
	}

	logger.Info("repository created/updated")
} else {
	// deletion timestamp is set, resource is being deleted
	if controllerutil.ContainsFinalizer(&resource, FinalizerName) {
		if err := api.DeleteRepository(resource.Spec.Owner, resource.Spec.Repo); err != nil {
			return ctrl.Result{}, err
		}

		// done finalization logic, remove finalizer
		controllerutil.RemoveFinalizer(&resource, FinalizerName)
		if err := r.Update(ctx, &resource); err != nil {
			return ctrl.Result{}, fmt.Errorf("unable to remove finalizer: %v", err)
		}

		logger.Info("repository deleted")
	}
}
// ...
```

With that we finish our implementation and pass the end to end test

# Test it out

- Create github personal access token with `repo` and `delete_repo` scope
- Export github token as `GITHUB_API_TOKEN` environment variable in your terminal
- Run `make install` to install CRD to your local kubernetes cluster
- Run `make run` to run controller in your terminal
- Update sample CR at `./config/samples/pnguyen.io_v1_githubrepository.yaml`
- In another terminal, run `kubectl apply -f ./config/samples/pnguyen.io_v1_githubrepository.yaml`
- Verify that new github repository created
- Update description of the repository at `./config/samples/pnguyen.io_v1_githubrepository.yaml` to something else
- Run `kubectl apply -f ./config/samples/pnguyen.io_v1_githubrepository.yaml`
- Verify that the repository description in github is updated
- Run `kubectl delete -f ./config/samples/pnguyen.io_v1_githubrepository.yaml`
- Verify that the repository is deleted in github
