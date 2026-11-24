import { JwtAuthGuard } from './jwt-auth.guard';
import { PermissionGuard } from './permission.guard';

export const GLOBAL_GUARDS = [JwtAuthGuard, PermissionGuard] as const;
