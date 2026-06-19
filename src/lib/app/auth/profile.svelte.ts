/**
 * Business responsibility: maintain Photon's browser-local account profiles so
 * account switching, guest identities, JWT refreshes, and user context loading
 * all share one durable source of truth.
 */
import { browser } from '$app/environment'
import { env } from '$env/dynamic/public'
import { DEFAULT_CLIENT_TYPE, type ClientType } from '$lib/api/base'
import { client, site } from '$lib/api/client.svelte'
import type { Community, GetSiteResponse, MyUserInfo } from '$lib/api/types'
import { publishedToDate } from '$lib/ui/util/date'
import { toast } from 'mono-svelte'
import { errorMessage } from '../error'
import { t } from '../i18n'
import { DEFAULT_INSTANCE_URL } from '../instance.svelte'
import { instanceToURL, moveItem } from '../util.svelte'
import { InboxService } from './inbox.svelte'

/**
 * Business purpose: read persisted account metadata only in the browser, because
 * server rendering must not invent or leak user-specific identity state.
 */
function getFromStorage<T>(key: string): T | undefined {
  if (!browser) return
  const lc = localStorage.getItem(key)
  if (!lc) return undefined

  return JSON.parse(lc)
}

/**
 * Business purpose: persist profile state after account changes so refreshes
 * preserve the same active identity and switcher ordering.
 */
function setFromStorage<T>(key: string, item: T, stringify: boolean = true) {
  if (!browser) return
  return localStorage.setItem(
    key,
    stringify ? JSON.stringify(item) : (item as string),
  )
}

export interface ProfileInfo {
  id: number
  instance: string
  jwt?: string
  user?: MyUserInfo
  username?: string
  avatar?: string
  favorites?: Community[]
  color?: string
  client: ClientType
}

/**
 * Business purpose: define the persisted account registry that restores the
 * switcher list and active account after a browser refresh.
 */
interface ProfileData {
  profiles: ProfileInfo[]
  // should be named currentId
  profile: number
}

/**
 * Business purpose: read legacy migration cookies when an instance moves users
 * from another frontend into Photon without forcing a fresh login.
 */
const getCookie = (key: string): string | undefined => {
  if (!browser) return undefined

  return document?.cookie
    ?.split(';')
    .map((c) => c.trim())
    .find((c) => c.split('=')?.[0] == key)
    ?.split('=')?.[1]
}

export class Profile {
  private static readonly DONATION_CHECK_TIMEOUT = 3 * 1000
  private static readonly DONATION_REMINDER_INTERVAL = 375 * 24 * 60 * 60 * 1000

  meta = $state<ProfileData>(
    normalizeProfileData(getFromStorage<ProfileData>('profileData')) ?? {
      profiles: [
        {
          id: 1,
          instance: DEFAULT_INSTANCE_URL,
          username: 'Guest',
          color: '#505050',
          client: DEFAULT_CLIENT_TYPE,
        },
      ],
      profile: 1,
    },
  )
  #current = $derived(
    this.meta.profiles.find((i) => i.id == this.meta.profile) ??
      this.getDefaultProfile(),
  )
  client = $derived(
    client({
      auth: this.#current.jwt,
      clientType: this.#current.client,
      instanceURL: this.#current.instance,
    }),
  )
  inbox: InboxService = $state(new InboxService(this))

  /**
   * Business purpose: provide the anonymous fallback identity used when a stored
   * selection points at a removed account or no account exists yet.
   */
  getDefaultProfile(): ProfileInfo {
    return {
      id: -1,
      instance: DEFAULT_INSTANCE_URL,
      client: DEFAULT_CLIENT_TYPE,
    }
  }

  /**
   * Business purpose: initialize account migration and reminder workflows once
   * the local account registry is available.
   */
  constructor() {
    this.normalizeProfiles()
    this.initCookieMigrate()
    this.donationPoll(Profile.DONATION_CHECK_TIMEOUT)
  }

  /**
   * Business purpose: expose the selected identity for UI, API clients, and
   * feature gates that need to know which account is currently acting.
   */
  get current() {
    return this.#current
  }

  /**
   * Business purpose: update the stored selected profile after fresh user data
   * arrives, while preserving the existing account slot in the switcher.
   */
  set current(value) {
    if (!value) return
    const index = this.meta.profiles.findLastIndex((i) => i.id === value.id)
    if (index != -1) this.meta.profiles[index] = value
  }

  /**
   * Business purpose: import a trusted migration token so users keep access
   * after the linked instance changes frontend ownership.
   */
  private async initCookieMigrate() {
    if (
      !(
        env.PUBLIC_MIGRATE_COOKIE &&
        this.meta.profiles.length == 0 &&
        env.PUBLIC_INSTANCE_URL
      )
    )
      return

    const jwt = getCookie('jwt')
    if (!jwt) return
    const result = await this.add(
      jwt,
      env.PUBLIC_INSTANCE_URL ?? '',
      DEFAULT_CLIENT_TYPE,
    )

    if (result)
      toast({
        content:
          'Your instance migrated frontends, and your account was transferred.',
        type: 'success',
      })
  }

  /**
   * Business purpose: gently remind eligible logged-in users about donations
   * according to Lemmy's recorded notification cadence.
   */
  private donationPoll(delay: number) {
    return setTimeout(() => {
      if (
        this.current.user?.local_user_view.local_user.last_donation_notification
      ) {
        const donationDate = publishedToDate(
          this.current.user?.local_user_view.local_user
            .last_donation_notification,
        )
        if (
          Date.now() - donationDate.getTime() >
          Profile.DONATION_REMINDER_INTERVAL
        ) {
          toast({
            content: t.get('toast.lemmyDonate'),
            duration: 3600 * 1000,
            long: true,
          })

          // lemmy js client donation dialog is broken
          fetch(
            `${instanceToURL(this.current.instance)}/api/v3/user/donation_dialog_shown`,
            {
              method: 'POST',
              headers: {
                authorization: `Bearer ${this.current.jwt}`,
              },
            },
          )
        }
      }
    }, delay)
  }

  /**
   * Business purpose: refresh the selected profile's user and site context so
   * navigation, permissions, and notification counts reflect the active account.
   */
  async fetchUserData() {
    const startId = this.#current.id
    if (this.#current.jwt) {
      site.data = undefined

      const res = await fetchUserContext(
        this.#current.jwt,
        this.#current.instance,
        this.#current.client,
      )
      if (!res?.user)
        toast({
          content:
            "Your account's instance did not return your user data. Your login may have expired.",
          type: 'error',
        })

      // TODO update authentication handling to not be this dynamic
      if (this.#current.id != startId) {
        console.error('profile was switched too fast, ID mismatch')
        return
      }

      site.data = res?.site
      this.#current.user = res?.user
      if (this.current.user) {
        this.#current.avatar = res?.user?.local_user_view.person.avatar
        this.#current.username = res?.user?.local_user_view.person.name
      }
      this.inbox.init()
    } else {
      if (browser) {
        site.data = undefined
        client({ instanceURL: this.#current.instance })
          .getSite()
          .then((res) => (site.data = res))
      }
    }

    return this
  }

  /**
   * Business purpose: add a newly authenticated account, or refresh the existing
   * account slot when the same user logs in again on the same instance.
   */
  async add(jwt: string, instance: string, type: ClientType) {
    try {
      const user = await fetchUserContext(jwt, instance, type)
      if (!user?.user) {
        throw new Error('No user data received')
      }

      this.normalizeProfiles()
      const existingIndex = this.findExistingProfileIndex(
        user.user,
        instance,
        type,
      )
      if (existingIndex != -1) {
        const existingProfile = this.meta.profiles[existingIndex]
        this.meta.profiles[existingIndex] = {
          ...existingProfile,
          instance,
          jwt,
          user: user.user,
          username: user.user.local_user_view.person.name,
          avatar: user.user.local_user_view.person.avatar,
          client: type,
        }
        this.meta.profile = existingProfile.id
        return user
      }

      const id = Math.max(...this.meta.profiles.map((p) => p.id), 0) + 1
      this.meta.profiles.unshift({
        id,
        instance,
        jwt,
        username: user.user.local_user_view.person.name,
        avatar: user.user.local_user_view.person.avatar,
        client: type,
      })
      this.meta.profile = id
      return user
    } catch (err) {
      toast({
        content: errorMessage(err as string),
        type: 'error',
      })
      return null
    }
  }

  /**
   * Business purpose: remove an account profile from the local switcher when the
   * user logs out or no longer wants that identity available.
   */
  remove(id: number) {
    this.meta.profiles.splice(
      this.meta.profiles.findIndex((p) => p.id == id),
      1,
    )
    if (id == this.meta.profile) this.meta.profile = -1
  }

  /**
   * Business purpose: let users reorder account profiles so their most-used
   * identities appear where they expect in account switchers.
   */
  move(id: number, up: boolean) {
    try {
      const index = this.meta.profiles.findIndex((i) => i.id == id)
      this.meta.profiles = moveItem(
        this.meta.profiles,
        index,
        index + (up ? -1 : 1),
      )
    } catch {
      /* empty */
    }
  }

  /**
   * Business purpose: determine whether the active account can access moderation
   * workflows globally or for a specific community.
   */
  isMod(community?: Community): boolean {
    if (!community) return (this.#current.user?.moderates.length ?? 0) > 0
    if (community.local && this.isAdmin) return true
    return (
      this.#current.user?.moderates.some(
        (m) => m.community.id === community.id,
      ) ?? false
    )
  }

  /**
   * Business purpose: determine whether the active account has site-level admin
   * privileges returned by the current instance context.
   */
  get isAdmin(): boolean {
    return (
      site.data?.admins.some(
        (i) => i.person.id == this.#current.user?.local_user_view.person.id,
      ) ?? false
    )
  }

  /**
   * Business purpose: identify the built-in anonymous profile so onboarding and
   * empty account states can distinguish it from user-created guests.
   */
  get isDefaultProfile(): boolean {
    return !this.#current.jwt && this.#current.instance == DEFAULT_INSTANCE_URL
  }

  /**
   * Business purpose: collapse duplicate logged-in account slots so the switcher
   * represents distinct identities instead of repeated login attempts.
   */
  private normalizeProfiles() {
    const normalized = normalizeProfileData(this.meta)
    if (!normalized) return

    this.meta.profiles = normalized.profiles
    this.meta.profile = normalized.profile
  }

  /**
   * Business purpose: find the stored account slot that corresponds to freshly
   * authenticated user data from the same instance and API family.
   */
  private findExistingProfileIndex(
    user: MyUserInfo,
    instance: string,
    type: ClientType,
  ) {
    return this.meta.profiles.findIndex((profile) =>
      isSameAuthenticatedProfile(profile, user, instance, type),
    )
  }

  /**
   * Business purpose: keep localStorage synchronized with account mutations and
   * trigger user context refreshes when the selected identity changes.
   */
  mainEffect = $effect.root(() => {
    // Sync with localStorage
    $effect(() => {
      const serialized = {
        ...this.meta,
        profiles: this.meta.profiles.map((p) => serializeUser(p)),
      }

      setFromStorage('profileData', serialized)

      // no more profiles left
      if (serialized.profiles.length == 0) {
        this.meta.profiles = [this.getDefaultProfile()]
        this.meta.profile = 1
      }
    })

    $effect(() => {
      this.fetchUserData()
    })
  })
}

export const profile = new Profile()

/**
 * Business purpose: load the instance's combined site and current-user payload
 * for one JWT so account state can be hydrated from authoritative server data.
 */
async function fetchUserContext(
  jwt: string,
  instance: string,
  type: ClientType,
): Promise<{ user?: MyUserInfo; site: GetSiteResponse } | undefined> {
  const sitePromise = client({
    instanceURL: instance,
    auth: jwt,
    clientType: type,
  }).getSite()

  const timer = setTimeout(
    () =>
      toast({
        content: `Still loading your user data...`,
        type: 'warning',
        loading: true,
      }),
    5000,
  )

  const site = await sitePromise
    .then((r) => {
      clearTimeout(timer)
      return r
    })
    .catch((e) => {
      toast({ content: `Failed to contact the instance. ${e}` })
    })

  if (!site) return

  return {
    user: site.my_user,
    site: site,
  }
}

/**
 * Business purpose: remove volatile user payloads before persistence so stored
 * profiles keep credentials and display metadata without caching full API state.
 */
function serializeUser(user: ProfileInfo): ProfileInfo {
  return {
    ...user,
    user: undefined,
  }
}

/**
 * Business purpose: repair stored account lists by merging repeated logged-in
 * profiles while preserving intentional guest profiles as separate identities.
 */
function normalizeProfileData(data?: ProfileData): ProfileData | undefined {
  if (!data) return

  const profiles: ProfileInfo[] = []
  const authenticatedProfileIndexes: Record<string, number | undefined> =
    Object.create(null)
  let selectedProfile = data.profile

  for (const profile of data.profiles) {
    const accountKey = profileAccountKey(profile)
    if (!accountKey) {
      profiles.push(profile)
      continue
    }

    const existingIndex = authenticatedProfileIndexes[accountKey]
    if (existingIndex === undefined) {
      authenticatedProfileIndexes[accountKey] = profiles.length
      profiles.push(profile)
      continue
    }

    profiles[existingIndex] = mergeDuplicateProfile(
      profiles[existingIndex],
      profile,
      selectedProfile,
    )
    if (profile.id == selectedProfile)
      selectedProfile = profiles[existingIndex].id
  }

  if (!profiles.some((profile) => profile.id == selectedProfile)) {
    selectedProfile = profiles[0]?.id ?? data.profile
  }

  return {
    ...data,
    profiles,
    profile: selectedProfile,
  }
}

/**
 * Business purpose: keep the preferred account row stable while carrying over
 * usable credentials and display metadata from a duplicate login row.
 */
function mergeDuplicateProfile(
  keptProfile: ProfileInfo,
  duplicateProfile: ProfileInfo,
  selectedProfile: number,
): ProfileInfo {
  const preferredProfile =
    duplicateProfile.id == selectedProfile ? duplicateProfile : keptProfile
  const fallbackProfile =
    preferredProfile.id == keptProfile.id ? duplicateProfile : keptProfile

  return {
    ...keptProfile,
    instance: preferredProfile.instance || fallbackProfile.instance,
    jwt: preferredProfile.jwt ?? fallbackProfile.jwt,
    user: preferredProfile.user ?? fallbackProfile.user,
    username: preferredProfile.username ?? fallbackProfile.username,
    avatar: preferredProfile.avatar ?? fallbackProfile.avatar,
    favorites: preferredProfile.favorites ?? fallbackProfile.favorites,
    color: preferredProfile.color ?? fallbackProfile.color,
    client: preferredProfile.client ?? fallbackProfile.client,
  }
}

/**
 * Business purpose: build the identity key used for stored authenticated
 * profiles, limiting dedupe to accounts that are unique on the same instance.
 */
function profileAccountKey(profile: ProfileInfo): string | undefined {
  if (!profile.jwt) return

  const username =
    profile.username ?? profile.user?.local_user_view.person.name ?? undefined
  if (!username) return

  return [
    normalizeProfileInstance(profile.instance),
    profileClientName(profile.client),
    username.trim().toLowerCase(),
  ].join('|')
}

/**
 * Business purpose: compare fresh login data against stored profile metadata so
 * reauthentication refreshes an account instead of duplicating it.
 */
function isSameAuthenticatedProfile(
  profile: ProfileInfo,
  user: MyUserInfo,
  instance: string,
  type: ClientType,
): boolean {
  if (!profile.jwt) return false
  if (
    normalizeProfileInstance(profile.instance) !=
    normalizeProfileInstance(instance)
  )
    return false
  if (profileClientName(profile.client) != profileClientName(type)) return false

  const profilePerson = profile.user?.local_user_view.person
  const userPerson = user.local_user_view.person
  if (
    profilePerson?.actor_id &&
    profilePerson.actor_id == userPerson.actor_id
  ) {
    return true
  }

  const profileUsername = profile.username ?? profilePerson?.name
  return profileUsername?.trim().toLowerCase() == userPerson.name.toLowerCase()
}

/**
 * Business purpose: canonicalize instance text so the same home instance is not
 * treated as different accounts due to protocol, casing, or trailing slashes.
 */
function normalizeProfileInstance(instance: string): string {
  return instance
    .trim()
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '')
    .toLowerCase()
}

/**
 * Business purpose: normalize the API family attached to a profile so account
 * identity comparisons stay stable across older persisted data.
 */
function profileClientName(type: ClientType | undefined): ClientType['name'] {
  return type?.name ?? DEFAULT_CLIENT_TYPE.name
}
