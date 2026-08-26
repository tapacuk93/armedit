/*
 * account.inc - one registered asmedit user.
 *
 * An account is only valid with BOTH accesses bound: the aicoin wallet token
 * that pays for its Claude calls, and the AWS credentials its instances are
 * provisioned under.  Registration refuses anything less.
 *
 * The asmedit key is the only one of these that ever leaves the server, and
 * the only credential a device ever holds.
 */
#ifndef ASMEDIT_ACCOUNT_INC
#define ASMEDIT_ACCOUNT_INC

#define ACCT_KEY        0       /* the issued key, hex                  */
#define ACCT_WALLET     72      /* aicoin API token                     */
#define ACCT_AKID       328     /* AWS access key id                    */
#define ACCT_SECRET     456     /* AWS secret access key                */
#define ACCT_REGION     584
#define ACCT_INSTANCE   616     /* the instance this account is running */
#define ACCT_USED       680
#define ACCT_SZ         704
#define ACCT_MAX        16

#endif
