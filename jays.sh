#!/bin/bash

# ==========================================
# Configuration & Styles
# ==========================================
GUM_OPTS=(--foreground 212 --border-foreground 62 --border rounded --align center --width 30 --margin "1 2" --padding "0 2")
GUM_STYLE_SUCCESS=(--foreground 121 --align left --width 40 --margin "1 2")
GUM_STYLE_INFO=(--foreground 121 --align left --width 40 --margin "1 2")
GUM_STYLE_ERROR=(--foreground 196 --align left --width 40 --margin "1 2")
GUM_STYLE_COMMIT=(--border rounded --padding "1 2" --margin "1 0" --foreground 226 --border-foreground 240)

# Global State
IS_COLOCATED=false
IS_GIT_ONLY=false
IS_STANDALONE=false

# ==========================================
# Helper Functions
# ==========================================

check_dependencies() {
  for cmd in jj gum git gh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "❌ Error: Required command '$cmd' not found. Please install it first."
      exit 1
    fi
  done

  if ! gh auth status >/dev/null 2>&1; then
    echo "❌ Error: GitHub CLI is not authenticated. Run 'gh auth login' first."
    exit 1
  fi
}

log_success() {
  gum style "${GUM_STYLE_SUCCESS[@]}" "$1"
}

log_error() {
  echo "❌ $1"
}

confirm_action() {
  gum confirm "$1"
}

show_header() {
  gum style "${GUM_OPTS[@]}" 'Jays' 'Jujutsu Git helper'
}

# ==========================================
# Initialization Logic
# ==========================================

init_repository() {
  # Check existence of folders
  local has_git=false
  local has_jj=false
  [ -d .git ] && has_git=true
  [ -d .jj ] && has_jj=true

  if ! $has_git && ! $has_jj; then
    init=$(gum choose \
      "standalone - Pure Jujutsu setup for modern version control" \
      "colocate - Initialize with Git integration for existing workflows" \
      "cancel - Exit without initializing" \
      --header "No .git or .jj found. How do you want to initialize JJ?" | cut -d' ' -f1)

    case "$init" in
    colocate)
      echo
      gum style --foreground 212 --border-foreground 62 --border rounded --align left --padding "1 2" --margin "0 2" \
        "Colocated setup will create:" "" "• Git repository (.git)" "• Jujutsu with Git integration (.jj)" \
        "• Initial commit in both systems" "• Branch synchronization between Git and Jujutsu" "" "Location: $(pwd)"
      echo
      
      if confirm_action "Proceed with colocated initialization?"; then
        git init
        BRANCH=$(git branch --show-current)
        echo
        jj git init --colocate
        echo
        jj bookmark create "$BRANCH" -r @
        echo
        jj commit -m "initial commit"
        echo
        git switch "$BRANCH"
        IS_COLOCATED=true
      else
        log_error "Initialization canceled."
        exit 0
      fi
      ;;
    standalone)
      echo
      gum style --foreground 212 --border-foreground 62 --border rounded --align left --padding "1 2" --margin "0 2" \
        "Standalone setup will create:" "" "• Pure Jujutsu repository (.jj)" "• First bookmark (you will name it)" \
        "• Initial commit" "• No Git integration" "" "Location: $(pwd)"
      echo
      
      if confirm_action "Proceed with standalone initialization?"; then
        jj git init
        echo
        echo "Create the first bookmark"
        BOOKMARK=$(gum input --placeholder "name your bookmark")
        if [ -n "$BOOKMARK" ]; then
          jj bookmark create "$BOOKMARK" -r @
          echo
          jj commit -m "initial commit"
          IS_STANDALONE=true
        else
          log_error "No bookmark name provided. Initialization canceled."
          exit 0
        fi
      else
        log_error "Initialization canceled."
        exit 0
      fi
      ;;
    cancel)
      log_error "Initialization canceled."
      exit 0
      ;;
    esac
    exit 0

  elif $has_git && ! $has_jj; then
    echo "Found Git repo but no JJ repo."
    if confirm_action "Do you want to initialize JJ and link it to the existing Git repo?"; then
      jj git init --git-repo .
      echo "JJ initialized and linked to Git repo."
    else
      log_error "JJ initialization canceled."
    fi
    exit 0
  fi

  # Set global state for existing repos
  if $has_jj && $has_git; then
    IS_COLOCATED=true
  elif $has_jj; then
    IS_STANDALONE=true
  fi
}

# ==========================================
# Core Actions
# ==========================================

get_commit_message() {
  local message=""
  
  if confirm_action "Generate commit message with AI?"; then
    # Generate default commit message with jjlama
    local default_msg
    default_msg=$(gum spin --spinner dot --title "Generating commit message..." --show-output -- bash -c "jjlama 2>/dev/null" || echo "")
   
    if [ -n "$default_msg" ]; then
      echo >&2
      echo "Generated commit message:" >&2
      gum style "${GUM_STYLE_COMMIT[@]}" -- "$default_msg" >&2
      echo >&2
      
      while true; do
        local choice
        choice=$(gum choose "accept" "edit" "regenerate" "cancel" --header "What would you like to do?")
        
        case "$choice" in
        accept)
          message="$default_msg"
          break
          ;;
        edit)
          message=$(gum input --placeholder "Final commit message" --value="$default_msg")
          [ -n "$message" ] && break || log_error "No message provided."
          ;;
        regenerate)
            default_msg=$(gum spin --spinner dot --title "Regenerating commit message..." --show-output -- bash -c "jjlama 2>/dev/null" || echo "")
            if [ -n "$default_msg" ]; then
               echo >&2
               echo "Generated commit message:" >&2
               gum style "${GUM_STYLE_COMMIT[@]}" -- "$default_msg" >&2
               echo >&2
            else
               echo "❌ Failed to generate message" >&2
            fi
          ;;
        cancel)
          echo "❌ Commit canceled." >&2
          return 1
          ;;
        esac
      done
    else
      # Fallback if jjlama returns empty
      message=$(gum input --placeholder "Final commit message")
    fi
  else
    message=$(gum input --placeholder "Final commit message")
  fi
  
  if [ -z "$message" ]; then
    echo "No message entered." >&2
    return 1
  fi
  
  echo "$message"
}

action_commit() {
  local message
  message=$(get_commit_message) || return

  local target_bookmark
  
  # For standalone, we might want to let user pick a bookmark if multiple exist, 
  # or just commit to current. The original script behavior for standalone was confusing:
  # it asked "Choose a branch to commit to" then committed and moved it.
  # For colocated, it used current git branch.
  
  if $IS_COLOCATED; then
    local branch
    branch=$(git branch --show-current)
    jj commit --message="$message"
    echo
    # Sync git branch
    jj bookmark move --from 'heads(::@- & bookmarks())' --to @-
    echo
    # Only switch git branch if we have one (may be detached HEAD)
    if [ -n "$branch" ]; then
      git switch "$branch"
      echo
    fi
    jj log --limit 3
    log_success "Created a new commit on ${branch:-current revision}"
    
    # Prompt to push (only if we have a branch name)
    if [ -n "$branch" ]; then
      try_push_bookmark "$branch"
    fi
  else
    # Standalone behavior - mimics original "commit to specific bookmark" flow
    target_bookmark=$(jj bookmark list | sed 's/:.*//' | gum choose --header="Choose a branch to commit to")
    if [ -n "$target_bookmark" ]; then
      jj commit --message="$message"
      echo
      jj bookmark move "$target_bookmark" --from "$target_bookmark" --to @-
      echo
      log_success "Committed to $target_bookmark"
      echo
      jj log --limit 3
      
      try_push_bookmark "$target_bookmark"
    else
      log_error "Commit canceled - no branch selected."
    fi
  fi
}

try_push_bookmark() {
  local bookmark="$1"
  if jj git remote list | grep -q .; then
    if confirm_action "Push '$bookmark' to remote?"; then
      local remote_count
      remote_count=$(jj git remote list | wc -l)
      local push_success=false
      
      if [ "$remote_count" -gt 1 ]; then
        local selected_remote
        selected_remote=$(jj git remote list | sed 's/ .*//' | gum choose --header="Choose remote to push to:")
        [ -n "$selected_remote" ] && jj git push -b "$bookmark" --remote "$selected_remote" && push_success=true
      else
        jj git push -b "$bookmark" && push_success=true
      fi

      if [ "$push_success" = true ]; then
        log_success "Pushed '$bookmark' to remote"
      fi
    fi
  fi
}

action_squash() {
  if gum confirm "Do you want to squash the current work into the parent commit"; then
    if $IS_COLOCATED; then
      local branch
      branch=$(git branch --show-current)
      jj squash
      echo
      git switch "$branch"
    else
      jj squash
    fi
    echo
    jj log --limit 3
    log_success "Squashed work to parent"
  fi
}

action_abandon() {
  if gum confirm "Do you want to abandon the current work"; then
    jj abandon --retain-bookmarks
    echo
    jj log --limit 3
    log_success "Abandoned current work"
  fi
}

action_new_revision() {
  if gum confirm "Do you want to create a new revision"; then
    local base_revision
    if $IS_COLOCATED; then
        local branch
        branch=$(git branch --show-current)
        base_revision=$({ echo "$branch"; echo "@"; echo "@-"; jj bookmark list | sed 's/:.*//' | grep -v "^$branch$"; } | gum choose --header="Choose base for new revision")
    else
        base_revision=$({ echo "@"; echo "@-"; jj bookmark list | sed 's/:.*//'; } | gum choose --header="Choose base for new revision")
    fi

    if [ -n "$base_revision" ]; then
      jj new "$base_revision"
      echo
      log_success "Created new revision from $base_revision"
    else
      log_error "No base selected."
    fi
  fi
}

action_undo() {
  if confirm_action "Undo the last operation?"; then
    jj undo
    echo
    if $IS_COLOCATED; then
      local branch
      branch=$(git branch --show-current)
      if [ -z "$branch" ]; then
        # Restore git to the main tracked branch after undo
        local main_branch
        main_branch=$(jj bookmark list | sed 's/:.*//' | head -1)
        if [ -n "$main_branch" ]; then
          git switch "$main_branch"
          echo
        fi
      fi
    fi
    jj log --limit 3
    log_success "Undid last operation"
  fi
}

action_bookmarks() {
  while true; do
    local action
    action=$(gum choose \
      "new - Create new branch/bookmark" \
      "switch - Switch to existing branch/bookmark" \
      "move - Move existing bookmark to different revision" \
      "create - Create new bookmark at specific revision" \
      "delete - Remove an existing bookmark" \
      "list - Display all bookmarks" \
      "back - Return to main menu" \
      --header "Bookmarks & Branches:" | cut -d' ' -f1)

    case "$action" in
    new)
      if confirm_action "Create a new branch/bookmark?"; then
        local name
        name=$(gum input --placeholder "Name your branch/bookmark")
        if [ -n "$name" ]; then
          jj new @-
          echo
          jj bookmark create "$name" -r @-
          echo
          jj log --limit 3
          log_success "Created and switched to '$name'"
        else
          log_error "No name provided."
        fi
      fi
      ;;
    switch)
      local target
      target=$(jj bookmark list | sed 's/:.*//' | gum choose --header="Switch to branch/bookmark:")
      if [ -n "$target" ]; then
        jj new "$target"
        echo
        jj log --limit 3
        log_success "Switched to '$target'"
      else
        log_error "No branch selected."
      fi
      ;;
    move)
      local src
      src=$(jj bookmark list | sed 's/:.*//' | gum choose --header="Choose a bookmark to move")
      if [ -n "$src" ]; then
        echo "Moving bookmark $src"
        local dest
        dest=$({ jj bookmark list | sed 's/:.*//'; printf "@\n@-\n"; } | gum choose --header="Choose where to move the bookmark")
        if [ -n "$dest" ]; then
          jj bookmark move -f "$src" -t "$dest"
          echo
          jj log --limit 3
          log_success "Moved bookmark"
        else
          log_error "No destination selected."
        fi
      else
        log_error "No bookmark selected."
      fi
      ;;
    create)
      local name
      name=$(gum input --header="Create new bookmark" --placeholder="Enter bookmark name")
      if [ -n "$name" ]; then
        local loc
        loc=$({ printf "@\n@-\n"; jj bookmark list | sed 's/:.*//'; } | gum choose --header="Choose location for new bookmark")
        if [ -n "$loc" ]; then
          jj bookmark create "$name" -r "$loc"
          echo
          jj log --limit 3
          log_success "Created bookmark $name"
        else
          log_error "No location selected."
        fi
      else
        log_error "No name provided."
      fi
      ;;
    delete)
      local target
      target=$(jj bookmark list | sed 's/:.*//' | gum choose --header="Choose bookmark to delete")
      if [ -n "$target" ]; then
        if confirm_action "Delete bookmark '$target'?"; then
          jj bookmark delete "$target"
          echo
          jj log --limit 3
          log_success "Deleted bookmark $target"
        fi
      else
        log_error "No bookmark selected."
      fi
      ;;
    list)
      echo "Current bookmarks:"
      jj bookmark list
      gum style "${GUM_STYLE_INFO[@]}" 'Listed all bookmarks'
      ;;
    back) return ;;
    *) log_error "Canceled action" ;;
    esac
  done
}

action_remotes() {
  while true; do
    local opts
    if jj git remote list | grep -q .; then
      opts=("push - Push a bookmark to remote" "pull - Fetch changes from remote" "list - Display remotes" "add - Add new remote" "remove - Remove remote" "create - Create & push to new GitHub repo" "back - Return")
    else
      opts=("add - Add new remote" "create - Create & push to new GitHub repo" "list - Display remotes" "back - Return")
    fi

    local action
    action=$(gum choose "${opts[@]}" --header "Choose a remote action:" | cut -d' ' -f1)

    case "$action" in
    push)
      local src
      # Default to current branch for colocated, or ask for bookmark
      if $IS_COLOCATED; then
        src=$(git branch --show-current)
      else
        src=$(jj bookmark list | grep -v '^\s*@' | sed 's/:.*//' | gum choose --header="Choose a bookmark to push")
      fi
      
      [ -z "$src" ] && { log_error "No bookmark selected."; continue; }

      local dest
      dest=$({ jj git remote list | sed 's/ .*//'; printf "new branch"; } | gum choose --header="Choose a remote branch")
      [ -z "$dest" ] && { log_error "No destination selected."; continue; }

      if [[ "$dest" == *new* ]]; then
        jj git push -b "$src"
      else
        jj git push -b "$src" --remote "$dest"
      fi
      log_success "Pushed '$src' to remote"
      ;;
    pull)
      jj git pull
      echo
      jj log --limit 3
      log_success "Pulled from remote"
      ;;
    add)
      local name url
      name=$(gum input --header="Add a new remote" --placeholder="Choose remote name")
      url=$(gum input --header="Input remote SSH URL" --placeholder="git@github.com:<USER>/<REPO>.git")
      if [ -n "$name" ] && [ -n "$url" ]; then
        jj git remote add "$name" "$url"
        echo
        jj git remote list
        log_success "Added remote $name"
      else
        log_error "Invalid input."
      fi
      ;;
    remove)
      local target
      target=$(jj git remote list | sed 's/ .*//' | gum choose --header="Choose a remote to remove")
      if [ -n "$target" ] && confirm_action "Remove remote '$target'?"; then
        jj git remote remove "$target"
        log_success "Removed remote $target"
      fi
      ;;
    create)
      local user repo visibility
      user=$(gh api user --jq '.login') || { log_error "Could not get GitHub username."; continue; }
      repo=$(gum input --header="Create GitHub repository" --placeholder="Enter repository name")
      [ -z "$repo" ] && continue
      
      visibility=$(gum choose "private" "public" --header "Repository visibility:")
      [ -z "$visibility" ] && continue

      echo "Creating repository $user/$repo..."
      if gh repo create "$repo" "--$visibility"; then
        echo
        local remote_url="git@github.com:$user/$repo.git"
        jj git remote add origin "$remote_url"
        
        local push_src
        if $IS_COLOCATED; then
           push_src=$(git branch --show-current)
        else
           push_src=$(jj bookmark list | grep -v '^\s*@' | sed 's/:.*//' | gum choose --header="Choose bookmark to push")
        fi

        if [ -n "$push_src" ] && confirm_action "Push '$push_src' to new repo?"; then
          jj git push -b "$push_src"
          log_success "Created repo and pushed $push_src"
        fi
      else
        log_error "Failed to create repository."
      fi
      ;;
    list)
      echo "Current remotes:"
      jj git remote list
      [ $? -ne 0 ] && echo "No remotes configured."
      gum style "${GUM_STYLE_INFO[@]}" 'Listed all remotes'
      ;;
    back) return ;;
    *) log_error "Canceled" ;;
    esac
  done
}

# ==========================================
# Main Execution Loop
# ==========================================

main() {
  check_dependencies
  show_header
  init_repository

  # Main Loop
  while true; do
    echo
    jj st
    echo

    local choices=(
      "commit - Create permanent commits (with AI option)"
      "squash - Merge current work into parent"
      "abandon - Discard current changes"
      "new - Create new empty revision"
      "undo - Undo the last operation"
      "bookmark - Manage bookmarks/branches"
      "remote - Manage remotes (push/pull)"
      "exit - Exit"
    )

    local action
    action=$(gum choose "${choices[@]}" --header "Choose your action:" | cut -d' ' -f1)

    case "$action" in
      commit)   action_commit ;;
      squash)   action_squash ;;
      abandon)  action_abandon ;;
      new)      action_new_revision ;;
      undo)     action_undo ;;
      bookmark) action_bookmarks ;;
      remote)   action_remotes ;;
      exit)     break ;;
      *)        log_error "Unknown action" ;;
    esac
  done
}

main
