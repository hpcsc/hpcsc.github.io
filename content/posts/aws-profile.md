---
title:  "An utility to switch AWS profiles"
description:  "An utility to switch AWS profiles"
date: 2018-09-13
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- golang
- aws
- infrastructure
categories:
- programming
- infrastructure
---

<pre>
<b>TLDR</b>

I created a tool to switch among multiple AWS profiles.
Installation and usage instruction are at <a href="https://github.com/hpcsc/aws-profile">GitHub repo</a>
</pre>

<pre>
NOTE: there have been some significant changes to the source code of `aws-profile` tool (you can follow the link above to check the latest source code) so some of the code mentioned below is no longer relevant. I'll update this blog post to reflect the latest change when I have some time
</pre>

## Introduction

If you are working with AWS frequently enough, you should be aware of AWS CLI and its 2 related configuration files:

- credentials file (default location is at `~/.aws/credentials`): store credentials for different aws profiles
- config file (default location is at `~/.aws/config`): store additional settings like region or more importantly the information about the AWS role that you can assume

For people that need to switch back and forth among several AWS profiles like me (there are times when I have up to 10 profiles in credentials file), managing which account is the current one is a nightmare.
Let's go through some of the common ways to manage current AWS profile as highlighted in https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html#config-settings-and-precedence

- Command line options: I don't want to specify the profile in every command that I invoke
- Setting of environment variables (AWS_PROFILE, AWS_DEFAULT_PROFILE, etc): this approach only works with current terminal session. Once you open a new tab or re-open your terminal, you need to set it again. You can export it in your shell startup script (`.bashrc`, `.zshrc` etc) but changing profile is troublesome (edit startup script and re-source it)
- CLI configuration file/AWS credentials file: need to manually edit those files, copy the credentials of the profile that you want to switch to and set to default profile credentials. This is tedious and repetitive.

### First attempt

I wrote a small shell script that uses fzf to switch among profiles:

``` shell
local pattern=${1}
local selected_profile=$(cat ~/.aws/credentials | awk '/\[.+\]/{ print substr($0, 2, length($0) - 2) }' | fzf-tmux --height 30% --reverse -1 -0 --header 'Select AWS profile' --query "$pattern")
eval "export AWS_DEFAULT_PROFILE=$selected_profile"
```

What it does is just grepping all profile names in credentials file, pipe that to fzf for interactive selection and export `AWS_DEFAULT_PROFILE` variable. This works but has the limitation of environment variable approach above (only last for current terminal session). This also doesn't handle the case of assuming role in AWS.

### Second Attempt

I then looked for librarys/tools that can parse ini file format (that credentials and config files use) but not many options for shell script. So I wrote a python script that manipulates directly the credentials/config files instead of just setting the environment variable. It works but significantly slower compared to the shell script (I can notice a few seconds delay after selecting a profile).

So that's how I ended up with writing a CLI program in Golang to manage AWS profile. Coincidentally I also wanted to try writing something in Golang since I'm new to this language.

## Code Structure

Source code: [https://github.com/hpcsc/aws-profile](https://github.com/hpcsc/aws-profile)

Example Usage:

![](https://raw.githubusercontent.com/hpcsc/aws-profile-utils/master/aws-profile-utils.gif "demo")

Disclaimer: I'm a total noob in Golang

The application is pretty simple. Starting from `main.go`, I created a map/dictionary of handlers, with the key is the command name (like `get`, `set`) and the value is an instance of Handler interface:

``` go
type Handler interface {
	Handle() (bool, string)
}
```

Each handler defines its own arguments (using `kingpin`) and what to do when it's invoked.

This is the function to create the handler map:

``` go
func createHandlerMap(app *kingpin.Application) map[string]handlers.Handler{
	getHandler := handlers.NewGetHandler(app)
	setHandler := handlers.NewSetHandler(app, nil, nil)
	versionHandler := handlers.NewVersionHandler(app)

	return map[string]handlers.Handler {
		getHandler.SubCommand.FullCommand(): getHandler,
		setHandler.SubCommand.FullCommand(): setHandler,
		versionHandler.SubCommand.FullCommand(): versionHandler,
	}
}
```

When the application is invoked with any command, the main function just needs to lookup the map based on command name and invoke the `Handle()` function.

There are only 2 main commands and their handlers: `GetHandler` and `SetHandler`

### GetHandler

This handler does a few things:
- inspects `config` file, look for `default` section, compare the values in that `default` section with the values in other profiles in the same file
- if there is a matching, return that value as current profile
- if not, inspects `credentials` file and do the same things

The reason it needs to look info `config` file before `credentials` file is because `config` file store configuration to assume a role and that will take precedence over `credentials` setting.

The constructor function of `GetHandler` just defines command name, flags that it supports and returns a struct with all necessary information for processing later:

``` go
func NewGetHandler(app *kingpin.Application) GetHandler {
	subCommand := app.Command("get", "get current AWS profile (that is set to default profile)")

	credentialsFilePath := subCommand.Flag("credentials-path", "Path to AWS Credentials file").Default("~/.aws/credentials").String()
	configFilePath := subCommand.Flag("config-path", "Path to AWS Config file").Default("~/.aws/config").String()

	return GetHandler{
		SubCommand: subCommand,
		Arguments:   GetHandlerArguments{
			CredentialsFilePath: credentialsFilePath,
			ConfigFilePath: configFilePath,
		},
	}
}
```

When `GetHandler.Handle()` is invoked, the handler parses the `config` and `credentials` files to Golang ini files, iterates and compares values as mentioned above. Here's snippet for `config` file processing:

``` go
defaultRoleArn := configDefaultSection.Key("role_arn").Value()
defaultSourceProfile := configDefaultSection.Key("source_profile").Value()

for _, section := range configFile.Sections() {
  if strings.Compare(section.Name(), "default") != 0 &&
    section.Haskey("role_arn") &&
    section.HasKey("source_profile") &&
    strings.Compare(section.Key("role_arn").Value(), defaultRoleArn) == 0 &&
    strings.Compare(section.Key("source_profile").Value(), defaultSourceProfile) == 0 {
    return true, fmt.Sprintf("assuming %s\n", section.Name())
  }
}
```

Logic for `credentials` is similar but it looks for `aws_access_key_id` instead.

### SetHandler

This handler does a bit more work:
- get all profile names from both `credentials` and `config` files
- pipe those profile names to fzf (invoked as a shell process) for user selection
- once a profile is selected:
  - if the selected profile is from credentials file:
    - set the default profile in credentials file with the credentials from selected profile
    - clear the default profile in config file (if have)
  - if the selected profile is from config file:
    - set the default profile in config file with `role_arn` and `source_profile` values of selected profile

The code is straightforward, only a few things to highlight:

- The handler used to print the output message right in the `Handle()` function after processing. But I find it difficult to test that so the handler now returns a tuple of boolean and string, indicating whether the operation is successful (and should exit with exit code 0) and what message it wants to display. The main function is the one that does the actual printing of the message. By this way I can invoke the handler in the test and verify the expected message easily:

  ``` go
  success, message := handler.Handle()
  if !strings.EqualFold(message, "") {
    fmt.Println(message)
  }

  if success {
    os.Exit(0)
  } else {
    os.Exit(1)
  }
  ```

- There are a few places that the handler causes side-effect like invoking fzf in a shell process and writing the updated config to file system. Again this is not so straightforward to test. I find mocking in Golang confusing and verbal so I tried to find alternative approach instead. I did a few searches on whether Golang has something like IO Monad like Haskell but unfortunately it doesn't have. So in the end I settle with extracting those side-effect logic to functions and let constructor take in functions with those signature:

  ``` go
  func NewSetHandler(app *kingpin.Application, selectProfileFn SelectProfileFn, writeToFileFn WriteToFileFn) SetHandler {
    // omitted

    finalSelectProfileFn := selectProfileByFzf
    if selectProfileFn != nil {
      finalSelectProfileFn = selectProfileFn
    }

    finalWriteToFileFn := writeToFile
    if writeToFileFn != nil {
      finalWriteToFileFn = writeToFileFn
    }

    // omitted
  }
  ```

Here the constructor takes in 2 function parameters: one is used when fzf is invoked, the other is used when config is written to file system. If no arguments are provided for those functions, default functions (`selectProfileByFzf` and `writeToFile`) are used instead.

I'm not entirely satisfied with this approach because the 2 function parameters are not used anywhere else except for the tests. And Golang doesn't support function overloading or default parameter so all the clients that use this constructor function needs to pass in the value `nil` if it doesn't want to override the behavior of those functions.

### VersionHandler

This handler is very simple. It just prints out a string with formatted `version` variable. This `version` variable is set to the string "undefined" by default and will be overwritten by Golang compiler during the build process

``` go
var version = "undefined"
func (handler VersionHandler) Handle() (bool, string) {
	fmt.Printf("aws-profile-utils (%s)", version)
	return true, ""
}
```

## Build Process

This project is hosted in github and uses travis for build and release. The build for master branch and tags are slightly different.

For commit to master branch:

- Travis picks up the commit, builds and tests
- If successful, rename the output binary (`aws-profile-utils`) to include OS type (`linux` or `osx`) and build number.
- Upload above binaries to Google Cloud Storage. I choose GCS because it has always-free tier.

For a new tag that is pushed to github:

- New tag that is pushed to github will create a release with the name that is same with tag name
- Travis picks up the commit, builds and tests
- If successful, rename the output binary (`aws-profile-utils`) to include OS type (`linux` or `osx`)
- Modify github release created in the 1st step to include binaries generated in the last step.

## Conclusion

Some personal reflection after writing the program:

- Golang is easy to get started.
- I feel Golang lacks many constructs to have the code as concise and elegant as other languages, .e.g. it doesn't have built-in way to filter or map a slice, something that is very common and available in most other languages. It's true that filtering logic is very trivial to implement in Golang but if it's not provided by the language itself, developers will need to keep writing it over and over again. And for this reason, I feel Golang is quite verbose.
- Testing in Golang is also unnatural and verbose. Even though I already used `testify` library for helping with assertion and mocking, I still feel mocking requires a lot of setup.

I may have a different opinion about above points if I have chance to play around more with Golang in the future.
