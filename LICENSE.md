```text
Business Source License 1.1

License text copyright © 2017 MariaDB Corporation Ab, All Rights Reserved.
"Business Source License" is a trademark of MariaDB Corporation Ab.

-----------------------------------------------------------------------------

Parameters

Licensor:             BARTERCRAFT PTE. LTD. (Singapore UEN 202418757N)

Licensed Work:        BarterLend's original implementations in:
                      src/CreditPool.sol; src/CreditPoolBase.sol;
                      src/CreditPoolFactory.sol (including CodeChunk);
                      src/CreditPoolRolloverExtension.sol; src/Delegator.sol;
                      src/facets/**; src/lib/** (including Set.sol.template),
                      as originally distributed by the Licensor, and their
                      modifications and derivative works.
                      The SEEDS, MarketsConfigParams and MarketsConfig
                      declarations in src/lib/MarketsConfig.sol and
                      third-party material are excluded.
                      The Licensed Work is (c) 2026 BARTERCRAFT PTE. LTD.

Additional Use Grant: You may make production use of the Licensed Work solely
                      to interact with Authorized Deployments, including
                      through independently developed applications,
                      interfaces, integrations, bots and extensions.

                      An "Authorized Deployment" is (a) an instance of the
                      Licensed Work deployed by the Licensor, or with the
                      Licensor's express written authorization, on the
                      blockchain network identified by the Licensor in its
                      official documentation or repository, or in that
                      authorization; and (b) any contract created by an
                      Authorized Deployment of CreditPoolFactory on the same
                      blockchain network, within the scope of any
                      authorization applicable to that factory.

                      Creating, configuring and using contracts through an
                      Authorized Deployment of CreditPoolFactory is
                      permitted under this grant.

                      For the avoidance of doubt, use of the Licensed Work
                      in local development environments, forks of a
                      blockchain network or public test networks, for
                      development, testing, auditing or security research,
                      is non-production use.

Change Date:          2030-10-15

Change License:       GNU General Public License v2.0 or later
                      (SPDX: GPL-2.0-or-later; see LICENSE-GPL-2.0)

-----------------------------------------------------------------------------

Terms

The Licensor hereby grants you the right to copy, modify, create derivative
works, redistribute, and make non-production use of the Licensed Work. The
Licensor may make an Additional Use Grant, above, permitting limited
production use.

Effective on the Change Date, or the fourth anniversary of the first publicly
available distribution of a specific version of the Licensed Work under this
License, whichever comes first, the Licensor hereby grants you rights under
the terms of the Change License, and the rights granted in the paragraph
above terminate.

If your use of the Licensed Work does not comply with the requirements
currently in effect as described in this License, you must purchase a
commercial license from the Licensor, its affiliated entities, or authorized
resellers, or you must refrain from using the Licensed Work.

All copies of the original and modified Licensed Work, and derivative works
of the Licensed Work, are subject to this License. This License applies
separately for each version of the Licensed Work and the Change Date may vary
for each version of the Licensed Work released by Licensor.

You must conspicuously display this License on each original or modified copy
of the Licensed Work. If you receive the Licensed Work in original or
modified form from a third party, the terms and conditions set forth in this
License apply to your use of that work.

Any use of the Licensed Work in violation of this License will automatically
terminate your rights under this License for the current and all other
versions of the Licensed Work.

This License does not grant you any right in any trademark or logo of
Licensor or its affiliates (provided that you may use a trademark or logo of
Licensor as expressly required by this License).

TO THE EXTENT PERMITTED BY APPLICABLE LAW, THE LICENSED WORK IS PROVIDED ON
AN “AS IS” BASIS. LICENSOR HEREBY DISCLAIMS ALL WARRANTIES AND CONDITIONS,
EXPRESS OR IMPLIED, INCLUDING (WITHOUT LIMITATION) WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, AND
TITLE.

MariaDB hereby grants you permission to use this License’s text to license
your works, and to refer to it using the trademark “Business Source License”,
as long as you comply with the Covenants of Licensor below.

Covenants of Licensor

In consideration of the right to use this License’s text and the “Business
Source License” name and trademark, Licensor covenants to MariaDB, and to all
other recipients of the licensed work to be provided by Licensor:

1. To specify as the Change License the GPL Version 2.0 or any later version,
   or a license that is compatible with GPL Version 2.0 or a later version,
   where “compatible” means that software provided under the Change License can
   be included in a program with software provided under GPL Version 2.0 or a
   later version. Licensor may specify additional Change Licenses without
   limitation.

2. To either: (a) specify an additional grant of rights to use that does not
   impose any additional restriction on the right granted in this License, as
   the Additional Use Grant; or (b) insert the text “None”.

3. To specify a Change Date.

4. Not to modify this License in any other way.

-----------------------------------------------------------------------------

Notice

The Business Source License (this document, or the "License") is not an Open
Source license. However, the Licensed Work will eventually be made available
under an Open Source License, as stated in this License.
```

## Separately licensed material

Original first-party code, documentation and configuration outside the
Licensed Work, including the excluded `SEEDS`, `MarketsConfigParams` and
`MarketsConfig` declarations and their copies and modifications, are
licensed under the GNU General Public License, version 2 or (at your option)
any later version ([GPL-2.0-or-later](LICENSE-GPL-2.0)).

You may import and compile `src/lib/MarketsConfig.sol` to use those public
declarations in independently developed software without making that
software subject to BUSL solely for that use. Applicable GPL conditions
still apply. This grant does not cover `MarketsConfigLib`, its algorithms
or the remaining implementation in that file, and does not offer GPL as an
alternative license for the Licensed Work before its BUSL transition.

Third-party material and license texts retain their own terms.
