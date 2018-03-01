---
title:  "Test drive a Kubernetes operator - Part 3"
description:  "Create a simple Kubernetes operator following TDD"
date: 2021-08-01
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

In the previous [post]({{< relref "/posts/test-drive-kubernetes-operator-2/index.md" >}}), we have basic functionalities of the operator implemented: create, update and delete.

Today we are going to add the function to clone from another repository when creating a new repository.

# Posts in the series

- [Scaffold and first slice of the operator: creation of github repository]({{< relref "/posts/test-drive-kubernetes-operator-1/index.md" >}})
- [Update and delete of github repository]({{< relref "/posts/test-drive-kubernetes-operator-2/index.md" >}})
- Creating of github repository by cloning another repository (This post)
- [Validation using webhooks]({{< relref "/posts/test-drive-kubernetes-operator-4/index.md" >}})

# End to end test

Our new end to end test looks almost exactly the same like creation end to end test:

```go
Context("When GithubRepository resource created with template repository", func() {
	var name, namespace string
	var githubRepository pnguyeniov1.GithubRepository

	BeforeEach(func() {
		namespace = "default"
		name = fmt.Sprintf("test-repository-%d", rand.IntnRange(1000, 9000))
	})

	It("should create github repository using github API", func() {
		githubRepository = pnguyeniov1.GithubRepository{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: namespace,
			},
			Spec: pnguyeniov1.GithubRepositorySpec{
				Owner:         "test-owner",
				Repo:          name,
				TemplateOwner: "template-owner",
				TemplateRepo:  "template-repo",
				Description:   "test-description",
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

		history, err := smocker.RequestByPath("/repos/template-owner/template-repo/generate", "POST", "name", name)
		Expect(err).NotTo(HaveOccurred())

		Expect(history.Response.Status).To(Equal(201))
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

There are 2 things that are different:
- We provide `TemplateOwner` and `TemplateRepo` in `GithubRepositorySpec`. These 2 properties don't exist in the spec yet and we will add them next
- Instead of verifying POST request to `/users/repos` like in creation test, we check POST to `/repos/{template-owner}/{template-repo}/generate` endpoint. We know this from Github API online reference.

To make the test compilable, we need to add 2 additional properties to `GithubRepositorySpec` in `api/v1/githubrepository_types.go`:

```go
type GithubRepositorySpec struct {
	// ...
	TemplateOwner string `json:"templateOwner,omitempty"`
	TemplateRepo  string `json:"templateRepo,omitempty"`
	// ...
}
```

# Update githubapi package

Current `githubapi.CreateOrUpdateRepository()` already takes 3 parameters and we need to pass in 2 additional parameters for template owner and repo. The number of parameters is a bit too many for my liking so I decide to move them to a separate struct:

```go
type CreateOrUpdateRepositoryRequest struct {
	Owner       string
	Repo        string
	Description string
}

func (a *api) CreateOrUpdateRepository(request CreateOrUpdateRepositoryRequest) error {
	// ...
}
```

This requires some update to existing tests and controller code but it's quite simple. After the change, make sure to re-run all the tests.

Next, add tests to verify correct github api endpoints called. These tests very similar to previous tests that we have written so I just go over them quickly:

```go
t.Run("call github api to create repository from template when template owner and repo are provided", func(t *testing.T) {
	token := "valid-token"
	repoName := fmt.Sprintf("test-repo-%d", rand.IntnRange(1000, 9000))
	api, err := New(context.TODO(), smocker.Url, smocker.Url, token)
	require.NoError(t, err)

	err = api.CreateOrUpdateRepository(CreateOrUpdateRepositoryRequest{
		Owner:         "test-owner",
		Repo:          repoName,
		Description:   "some-description",
		TemplateOwner: "template-owner",
		TemplateRepo:  "template-repo",
	})

	require.NoError(t, err)
	history, err := smocker.RequestByPath("/repos/template-owner/template-repo/generate", "POST", "name", repoName)
	require.NoError(t, err)
	require.Equal(t, http.StatusCreated, history.Response.Status)
	require.Equal(t, repoName, history.Response.Body.(map[string]interface{})["name"])
})
```

Add smocker definition for new endpoint, update `CreateOrUpdateRepositoryRequest` to include 2 new fields, and add simplest implementation that we can think of:

```go
// ...
if resp.StatusCode == http.StatusNotFound {
	if request.TemplateOwner != "" && request.TemplateRepo != "" {
		_, _, err = a.client.Repositories.CreateFromTemplate(a.ctx, request.TemplateOwner, request.TemplateRepo, &github.TemplateRepoRequest{
			Name:        &request.Repo,
			Description: &request.Description,
		})
		if err != nil {
			return fmt.Errorf("failed to create repository %s from template %s/%s: error: %v",
				request.Repo,
				request.TemplateOwner,
				request.TemplateRepo,
				err)
		}
	} else {
		_, _, err = a.client.Repositories.Create(a.ctx, "", &repository)
		if err != nil {
			return fmt.Errorf("failed to create repository %s: error: %v", request.Repo, err)
		}
	}
} else {
	// ...
}
// ...
```

Using new feature in controller is as simple as passing additional parameters from custom resource spec to githubapi call:

```go
// controllers/githubrepository_controller.go
if err := api.CreateOrUpdateRepository(githubapi.CreateOrUpdateRepositoryRequest{
	Owner:         resource.Spec.Owner,
	Repo:          resource.Spec.Repo,
	Description:   resource.Spec.Description,
	TemplateOwner: resource.Spec.TemplateOwner,
	TemplateRepo:  resource.Spec.TemplateRepo,
}); err != nil {
	return ctrl.Result{}, err
}
```

End to end function should pass now

# Test it out

- Export github token as `GITHUB_API_TOKEN` environment variable in your terminal
- Run `make install` to install CRD to your local kubernetes cluster
- Run `make run` to run controller in your terminal
- Update sample CR at `./config/samples/pnguyen.io_v1_githubrepository.yaml`:

```yaml
apiVersion: pnguyen.io.pnguyen.io/v1
kind: GithubRepository
metadata:
  name: operator-test
spec:
  owner: hpcsc
  repo: operator-test
  description: my sample operator test
  templateOwner: hpcsc
  templateRepo: asdf-plugin-template
```

Note that the repository to be used as template must be marked as template in github as instructed [here](https://docs.github.com/en/github/creating-cloning-and-archiving-repositories/creating-a-repository-on-github/creating-a-template-repository)

- In another terminal, run `kubectl apply -f ./config/samples/pnguyen.io_v1_githubrepository.yaml`
- Verify that new github repository created with content from `https://github.com/hpcsc/asdf-plugin-template`
